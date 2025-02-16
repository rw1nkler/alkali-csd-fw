/*
 * Copyright 2021-2022 Western Digital Corporation or its affiliates
 * Copyright 2021-2022 Antmicro
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include "tc.h"
#include "dma.h"
#include "cmd.h"

#include <sys/printk.h>

#include <string.h>
#include <math.h>
#define DEBUG

static nvme_tc_priv_t p_tc = {0};

static char __aligned(16) cmd_slab_buffer[sizeof(nvme_cmd_priv_t)*NVME_CMD_SLAB_SIZE];

static char __aligned(16) prp_slab_buffer[NVME_PRP_LIST_SIZE*NVME_PRP_SLAB_SIZE];

static void nvme_tc_cc_handler(nvme_tc_priv_t *priv)
{
	uint32_t cc = sys_read32(priv->base + NVME_TC_REG_CC);
	uint32_t csts = sys_read32(priv->base + NVME_TC_REG_CSTS);

	if(pow(2, NVME_TC_GET_FIELD(cc, CC_IOCQES)) != NVME_TC_CQ_ENTRY_SIZE) {
		printk("Invalid IO CQ entry size! (%d)\n", (int)pow(2, NVME_TC_GET_FIELD(cc, CC_IOCQES)));
	}
	if(pow(2, NVME_TC_GET_FIELD(cc, CC_IOSQES)) != NVME_TC_SQ_ENTRY_SIZE) {
		printk("Invalid IO SQ entry size! (%d)\n", (int)pow(2, NVME_TC_GET_FIELD(cc, CC_IOSQES)));
	}

	if(NVME_TC_GET_FIELD(cc, CC_SHN)) {
#ifdef DEBUG
		printk("Shutdown notification detected\n");
#endif
		NVME_TC_SET_FIELD(csts, NVME_TC_SHUTDOWN_COMPLETE, CSTS_SHST);
	}

	if(NVME_TC_GET_FIELD(cc, CC_AMS))
		printk("Unsupported arbitration method selected!\nWe only support Round Robin (000b)\n");

	priv->memory_page_size = pow(2, NVME_TC_GET_FIELD(cc, CC_MPS) + 12);

	if(priv->memory_page_size != NVME_PRP_LIST_SIZE)
		printk("Unsupported page size selected!\n");

	if(NVME_TC_GET_FIELD(cc, CC_CSS))
		printk("Unsupported command set selected!\nWe only support NVM command set (000b)\n");

	if(cc && NVME_TC_REG_CC_EN) {
		priv->enabled = true;
#ifdef DEBUG
		printk("Controller enabled\n");
#endif
		csts |= NVME_TC_REG_CSTS_RDY;
	} else if (priv->enabled) {
		priv->enabled = false;
#ifdef DEBUG
		printk("Controller reset requested\n");
#endif
		csts &= ~NVME_TC_REG_CSTS_RDY;
	}

	sys_write32(csts, priv->base + NVME_TC_REG_CSTS);
}

static void nvme_tc_aqa_handler(nvme_tc_priv_t *priv)
{
	uint32_t aqa = sys_read32(priv->base + NVME_TC_REG_AQA);

	priv->cq_size[ADM_QUEUE_ID] = NVME_TC_GET_FIELD(aqa, AQA_ACQS) + 1; // 0's based values
	priv->sq_size[ADM_QUEUE_ID] = NVME_TC_GET_FIELD(aqa, AQA_ASQS) + 1;
}

static void nvme_tc_asq_handler(nvme_tc_priv_t *priv)
{
	uint32_t asq0 = sys_read32(priv->base + NVME_TC_REG_ASQ_0);
	uint32_t asq1 = sys_read32(priv->base + NVME_TC_REG_ASQ_1);

	priv->sq_base[ADM_QUEUE_ID] = ((uint64_t)asq1 << 32) | asq0;
	priv->sq_valid[ADM_QUEUE_ID] = true;
}

static void nvme_tc_acq_handler(nvme_tc_priv_t *priv)
{
	uint32_t acq0 = sys_read32(priv->base + NVME_TC_REG_ACQ_0);
	uint32_t acq1 = sys_read32(priv->base + NVME_TC_REG_ACQ_1);

	priv->cq_base[ADM_QUEUE_ID] = ((uint64_t)acq1 << 32) | acq0;
	priv->cq_valid[ADM_QUEUE_ID] = true;
}

uint64_t nvme_tc_get_sq_addr(nvme_tc_priv_t *priv, const int qid)
{
	uint64_t addr = priv->sq_base[qid] + priv->sq_head[qid] * NVME_TC_SQ_ENTRY_SIZE;

	priv->sq_head[qid] = (priv->sq_head[qid] + 1) % priv->sq_size[qid];
	return addr;
}

uint64_t nvme_tc_get_adm_sq_addr(nvme_tc_priv_t *priv)
{
	return nvme_tc_get_sq_addr(priv, ADM_QUEUE_ID);
}

void nvme_tc_cq_notify(nvme_tc_priv_t *priv, const int qid)
{
	uint8_t iv = priv->cq_iv[qid];
	sys_write32(1<<iv,priv->base + NVME_TC_REG_IRQ_HOST);
}

uint64_t nvme_tc_get_cq_addr(nvme_tc_priv_t *priv, const int qid)
{
	uint64_t addr;
	uint32_t next_tail = (priv->cq_tail[qid] + 1) % priv->cq_size[qid];

	if(priv->cq_head[qid] != next_tail) {
		if(priv->cq_tail[qid] == 0) // We need to use flip the phase bit after each pass
			priv->cq_phase[qid] = !priv->cq_phase[qid];

		addr = priv->cq_base[qid] + priv->cq_tail[qid] * NVME_TC_CQ_ENTRY_SIZE;
		priv->cq_tail[qid] = next_tail;
	} else {
		addr = 0;
	}

	return addr;
}

static void nvme_tc_tail_handler(nvme_tc_priv_t *priv, const int qid)
{
	uint32_t tail = sys_read32(priv->base + DOORBELL_TAIL(qid));

	priv->sq_tail[qid] = tail;
	printk("%s\n", __FUNCTION__);

	while(priv->sq_tail[qid] != priv->sq_head[qid]) {
		uint64_t host_addr = nvme_tc_get_sq_addr(priv, qid);
		nvme_cmd_priv_t *arg;
		if(k_mem_slab_alloc(&priv->cmd_slab, (void**)&arg, K_NO_WAIT) == 0) {
			memset(arg, 0, sizeof(*arg));
			arg->qid = qid;
			arg->tc = priv;
			nvme_dma_xfer_host_to_mem(priv->dma_priv, host_addr, (uint32_t)arg->sq_buf, NVME_TC_SQ_ENTRY_SIZE, nvme_cmd_handler, arg);
		} else {
			printk("Failed to allocate memory for command!(tail: %d, head: %d)\n", priv->sq_tail[qid], priv->sq_head[qid]);
		}
	}
}

static void nvme_tc_head_handler(nvme_tc_priv_t *priv, const int qid)
{
	uint32_t head = sys_read32(priv->base + DOORBELL_HEAD(qid));

	priv->cq_head[qid] = head;
}

static void nvme_tc_irq_handler(void *arg)
{
	nvme_tc_priv_t *priv = (nvme_tc_priv_t*)arg;
	bool io_queue_handled = false;

	printk("%s\n", __FUNCTION__);
	while(sys_read32(priv->base + NVME_TC_REG_IRQ_STA)) {
		uint16_t reg = sys_read32(priv->base + NVME_TC_REG_IRQ_DAT) * 4;
#ifdef DEBUG
		printk("Host write to reg 0x%04x: 0x%08x\n", reg, sys_read32(priv->base + reg));
#endif
		switch(reg) {
			case NVME_TC_REG_CC:
				printk("NVME_TC_REG_CC\n");
				nvme_tc_cc_handler(priv);
				break;
			case NVME_TC_REG_AQA:
				printk("NVME_TC_REG_AQA\n");
				nvme_tc_aqa_handler(priv);
				break;
			case NVME_TC_REG_ASQ_0:
				printk("NVME_TC_REG_ASQ_0\n");
				/* This will be handled in ASQ_1 handler */
				break;
			case NVME_TC_REG_ASQ_1:
				printk("NVME_TC_REG_ASQ_1\n");
				nvme_tc_asq_handler(priv);
				break;
			case NVME_TC_REG_ACQ_0:
				printk("NVME_TC_REG_ACQ_0\n");
				/* This will be handled in ACQ_1 handler */
				break;
			case NVME_TC_REG_ACQ_1:
				printk("NVME_TC_REG_ACQ_1\n");
				nvme_tc_acq_handler(priv);
				break;
			case NVME_TC_REG_ADM_TAIL:
				printk("NVME_TC_REG_ADM_TAIL\n");
				nvme_tc_tail_handler(priv, ADM_QUEUE_ID);
				break;
			case NVME_TC_REG_ADM_HEAD:
				printk("NVME_TC_REG_ADM_HEAD\n");
				nvme_tc_head_handler(priv, ADM_QUEUE_ID);
				break;
			default:
				printk("DEFAULT\n");
				for(int i = 0; i < QUEUES; i++) {
					if(reg == NVME_TC_REG_IO_TAIL(i)) {
						nvme_tc_tail_handler(priv, i + 1);
						io_queue_handled = true;
						break;
					} else if(reg == NVME_TC_REG_IO_HEAD(i)) {
						nvme_tc_head_handler(priv, i + 1);
						io_queue_handled = true;
						break;
					}
				}
				if(!io_queue_handled)
					printk("Register 0x%04x write not handled!\n", reg);
		}
	}
}

void nvme_tc_irq_init(void)
{
	printk("Enabling TC interrupts\n");
	IRQ_CONNECT(DT_INST_0_NVME_TC_IRQ_0, DT_INST_0_NVME_TC_IRQ_0_PRIORITY, nvme_tc_irq_handler, &p_tc, DT_INST_0_NVME_TC_IRQ_0_FLAGS);
	irq_enable(DT_INST_0_NVME_TC_IRQ_0);
	printk("TC interrupts enabled\n");
}

nvme_tc_priv_t *nvme_tc_init(void *dma_priv)
{
	nvme_tc_priv_t *priv = &p_tc;

	priv->base = (mem_addr_t)DT_INST_0_NVME_TC_BASE_ADDRESS;

	priv->dma_priv = dma_priv;

	k_mem_slab_init(&priv->cmd_slab, cmd_slab_buffer, sizeof(nvme_cmd_priv_t), NVME_CMD_SLAB_SIZE);

	k_mem_slab_init(&priv->prp_slab, prp_slab_buffer, NVME_PRP_LIST_SIZE, NVME_PRP_SLAB_SIZE);

	printk("Clearing registers\n");
	for(int i = 0; i < NVME_TC_REG_IRQ_STA; i+=4)
		sys_write32(0, priv->base + i);

	return priv;
}
