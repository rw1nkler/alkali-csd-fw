/*
 * Copyright 2021-2022 Western Digital Corporation or its affiliates
 * Copyright 2021-2022 Antmicro
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <errno.h>
#include <metal/atomic.h>
#include <metal/assert.h>
#include <metal/device.h>
#include <metal/sys.h>
#include <metal/irq.h>
#include <metal/utilities.h>
#include <openamp/rpmsg_virtio.h>
#include "platform_info.h"
#include "rsc_table.h"

/* Cortex R5 memory attributes */
#define DEVICE_SHARED		0x00000001U /* device, shareable */
#define DEVICE_NONSHARED	0x00000010U /* device, non shareable */
#define NORM_NSHARED_NCACHE	0x00000008U /* Non cacheable  non shareable */
#define NORM_SHARED_NCACHE	0x0000000CU /* Non cacheable shareable */
#define	PRIV_RW_USER_RW		(0x00000003U<<8U) /* Full Access */

#define SHARED_MEM_PA  0x7ff00000UL
#define SHARED_MEM_SIZE  0x100000UL
#define SHARED_BUF_OFFSET 0x8000UL

#define _rproc_wait() ({ \
		__asm volatile("wfi"); \
	})

static struct remoteproc_priv rproc_priv;

static struct remoteproc rproc_inst;

/* processor operations from r5 to a53. It defines
 * notification operation and remote processor managementi operations.
 */
extern struct remoteproc_ops zynqmp_r5_a53_proc_ops;

/* RPMsg virtio shared buffer pool */
static struct rpmsg_virtio_shm_pool shpool;

static struct remoteproc *
platform_create_proc(int proc_index, int rsc_index)
{
	void *rsc_table;
	int rsc_size;
	int ret;
	metal_phys_addr_t pa;

	(void) proc_index;
	rsc_table = get_resource_table(rsc_index, &rsc_size);

	/* Initialize remoteproc instance */
	if (!remoteproc_init(&rproc_inst, &zynqmp_r5_a53_proc_ops,
				&rproc_priv)) {
		printk("returned null\n");
		return NULL;
	}

	/*
	 * Mmap shared memories
	 * Or shall we constraint that they will be set as carved out
	 * in the resource table?
	 */
	/* mmap resource table */
	pa = (metal_phys_addr_t)rsc_table;
	(void *)remoteproc_mmap(&rproc_inst, &pa,
				NULL, rsc_size,
				NORM_NSHARED_NCACHE|PRIV_RW_USER_RW,
				&rproc_inst.rsc_io);
	/* mmap shared memory */
	pa = SHARED_MEM_PA;
	(void *)remoteproc_mmap(&rproc_inst, &pa,
				NULL, SHARED_MEM_SIZE,
				NORM_NSHARED_NCACHE|PRIV_RW_USER_RW,
				NULL);

	/* parse resource table to remoteproc */
	ret = remoteproc_set_rsc_table(&rproc_inst, rsc_table, rsc_size);
	if (ret) {
		printk("Failed to initialize remoteproc\n");
		remoteproc_remove(&rproc_inst);
		return NULL;
	}
	printk("Initialize remoteproc successfully.\n");

	return &rproc_inst;
}

int platform_init(void **platform)
{
	unsigned long proc_id = 0;
	unsigned long rsc_id = 0;
	struct remoteproc *rproc;

	if (!platform) {
		printk("Failed to initialize platform: NULL pointer to store platform data.\n");
		return -1;
	}
	rproc = platform_create_proc(proc_id, rsc_id);
	if (!rproc) {
		printk("Failed to create remoteproc device.\n");
		return -EINVAL;
	}
	*platform = rproc;
	return 0;
}

struct  rpmsg_device *
platform_create_rpmsg_vdev(void *platform, unsigned int vdev_index,
			   unsigned int role,
			   void (*rst_cb)(struct virtio_device *vdev),
			   rpmsg_ns_bind_cb ns_bind_cb)
{
	struct remoteproc *rproc = platform;
	struct rpmsg_virtio_device *rpmsg_vdev;
	struct virtio_device *vdev;
	void *shbuf;
	struct metal_io_region *shbuf_io;
	int ret;

	rpmsg_vdev = metal_allocate_memory(sizeof(*rpmsg_vdev));
	printk("allocated memory for rpmsg_vdev\n");
	if (!rpmsg_vdev)
		return NULL;
	shbuf_io = remoteproc_get_io_with_pa(rproc, SHARED_MEM_PA);
	if (!shbuf_io)
		return NULL;
	shbuf = metal_io_phys_to_virt(shbuf_io,
				      SHARED_MEM_PA + SHARED_BUF_OFFSET);

	printk("creating remoteproc virtio\n");
	vdev = remoteproc_create_virtio(rproc, vdev_index, role, rst_cb);
	if (!vdev) {
		printk("failed remoteproc_create_virtio\n");
		goto err1;
	}

	printk("initializing rpmsg shared buffer pool\n");
	/* Only RPMsg virtio master needs to initialize
	 * the shared buffers pool
	 */
	rpmsg_virtio_init_shm_pool(&shpool, shbuf,
				   (SHARED_MEM_SIZE - SHARED_BUF_OFFSET));

	printk("initializing rpmsg vdev\n");
	/* RPMsg virtio slave can set shared buffers pool argument to NULL */
	ret =  rpmsg_init_vdev(rpmsg_vdev, vdev, ns_bind_cb,
			       shbuf_io,
			       &shpool);
	if (ret) {
		printk("failed rpmsg_init_vdev\n");
		goto err2;
	}
	printk("initializing rpmsg vdev\n");
	return rpmsg_virtio_get_rpmsg_device(rpmsg_vdev);
err2:
	remoteproc_remove_virtio(rproc, vdev);
err1:
	metal_free_memory(rpmsg_vdev);
	return NULL;
}

int platform_poll(void *priv)
{
	struct remoteproc *rproc = priv;
	struct remoteproc_priv *prproc;
	unsigned int flags;

	prproc = rproc->priv;
	while (1) {
		flags = metal_irq_save_disable();
		if (!(atomic_flag_test_and_set(&prproc->ipi_nokick))) {
			metal_irq_restore_enable(flags);
			remoteproc_get_notification(rproc, RSC_NOTIFY_ID_ANY);
			break;
		}
		_rproc_wait(); /* wait for interrupt */
		metal_irq_restore_enable(flags);
	}
	return 0;
}

void platform_cleanup(void *platform)
{
	struct remoteproc *rproc = platform;

	if (rproc)
		remoteproc_remove(rproc);
}

extern int zynqmp_r5_a53_proc_irq_handler(int, void *);

int irq_handler(int cpu_id)
{
	return zynqmp_r5_a53_proc_irq_handler(cpu_id, &rproc_inst);
}
