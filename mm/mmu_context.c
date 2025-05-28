/* Copyright (C) 2009 Red Hat, Inc.
 *
 * See ../COPYING for licensing terms.
 */

#include <linux/mm.h>
#include <linux/sched.h>
#include <linux/sched/mm.h>
#include <linux/sched/task.h>
#include <linux/mmu_context.h>
#include <linux/export.h>

#include <asm/mmu_context.h>

/*
 * use_mm
 *	Makes the calling kernel thread take on the specified
 *	mm context.
 *	(Note: this routine is intended to be called only
 *	from a kernel thread context)
 */
void use_mm(struct mm_struct *mm)
{
	struct mm_struct *active_mm;
	struct task_struct *tsk = current;

	task_lock(tsk);
	active_mm = tsk->active_mm;
	if (active_mm != mm) {
		mmgrab(mm);
		tsk->active_mm = mm;
	}
	tsk->mm = mm;
	membarrier_update_current_mm(mm);
	switch_mm(active_mm, mm, tsk);
	task_unlock(tsk);
#ifdef finish_arch_post_lock_switch
	finish_arch_post_lock_switch();
#endif

	/*
	 * When a kthread starts operating on an address space, the loop
	 * in membarrier_{private,global}_expedited() may not observe
	 * that tsk->mm, and not issue an IPI. Membarrier requires a
	 * memory barrier after storing to tsk->mm, before accessing
	 * user-space memory. A full memory barrier for membarrier
	 * {PRIVATE,GLOBAL}_EXPEDITED is implicitly provided by
	 * mmdrop(), or explicitly with smp_mb().
	 */
	if (active_mm != mm)
		mmdrop(active_mm);
	else
		smp_mb();
}
EXPORT_SYMBOL_GPL(use_mm);

/*
 * unuse_mm
 *	Reverses the effect of use_mm, i.e. releases the
 *	specified mm context which was earlier taken on
 *	by the calling kernel thread
 *	(Note: this routine is intended to be called only
 *	from a kernel thread context)
 */
void unuse_mm(struct mm_struct *mm)
{
	struct task_struct *tsk = current;

	task_lock(tsk);
	/*
	 * When a kthread stops operating on an address space, the loop
	 * in membarrier_{private,global}_expedited() may not observe
	 * that tsk->mm, and not issue an IPI. Membarrier requires a
	 * memory barrier after accessing user-space memory, before
	 * clearing tsk->mm.
	 */
	smp_mb__after_spinlock();
	sync_mm_rss(mm);
	tsk->mm = NULL;
	membarrier_update_current_mm(NULL);
	/* active_mm is still 'mm' */
	enter_lazy_tlb(mm, tsk);
	task_unlock(tsk);
}
EXPORT_SYMBOL_GPL(unuse_mm);
