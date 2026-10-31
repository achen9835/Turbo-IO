/* Non-deleting SysStateMonitor destructor entry for the pinned 1.0.5.12 profile.
 * Requires the expanded allocation AND constructor-call patch. */
.syntax unified
.thumb
.fpu fpv5-sp-d16
.section .text.ce_sys_destroy_entry,"ax",%progbits
.global ce_sys_destroy_entry
.type ce_sys_destroy_entry,%function
.thumb_func
ce_sys_destroy_entry:
    push.w {r0-r3,r12,lr}
    mrs r3,apsr
    vmrs r12,fpscr
    push.w {r3,r12}
    vpush {s0-s15}
    bl ce_native_sys_before_destroy
    vpop {s0-s15}
    pop.w {r3,r12}
    vmsr fpscr,r12
    msr APSR_nzcvqg,r3
    pop.w {r0-r3,r12,lr}
    /* Exact displaced bytes: 98 b5 08 4b. Replay push + relocated literal. */
    push {r3,r4,r7,lr}
    ldr r3,=0x181e6e8c
    b.w ce_stock_sys_destroy_resume
.size ce_sys_destroy_entry,.-ce_sys_destroy_entry
