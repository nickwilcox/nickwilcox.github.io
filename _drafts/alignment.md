---
title: Alignment
categories:
  - blog
tags:
  - Optimisation
  - Rust
  - x86
  - ARM
---

## What is Alignment

## History on X86

When SSE was introduced it had two ways of loading packed values from memory into a register, `MOVAPS` (**MOV**e **A**ligned **P**acked **S**ingle-Precision) and `MOVUPS` (**MOV**e **U**naligned **P**acked **S**ingle-Precision). Passing a unaligned address to the aligned instruction would result in an exception. It was necessary to expose this level of detail to software due to significant performance penalties of unaligned memory operations. It was the job of the programmer to choose between absolute best performance or making the code more flexible (*improve this sentence*).

The performance penalty was actually two parts. First the `MOVUPS` instruction itself was slower to issue the loads. Secondly the transfer from memory was also slower.

This was situation for long time. Long enough for *"Using strictly aligned access is always fastest"* to become a rule of thumb

That changed when Intel introduced the Nehalem micro-architecture in 2009. `MOVAPS` and `MOVUPS` now took the same of cycles to issue. However the penalty for transferring unaligned data from memory remained. If you passed an aligned address the `MOVUPS` you could expect the same overall performance as if you used `MOVAPS`.

Each subsequent desktop or server micro-architecture design from Intel has improved the performance of actual memory transfer. *Mention crossing cache and page boundaries?*

*Insert benchmarks*

https://community.intel.com/t5/Intel-ISA-Extensions/SSE-and-AVX-behavior-with-aligned-unaligned-instructions/td-p/1170000

###

There's an extra tangent to explore. SSE instructions can have either register or memory operands. So we could have a instruction sequence

```nasm
movaps      xmm0, xmmword ptr [rcx] ; move the 4 f32's at the address contained in rcx into register xmm0
movaps      xmm1, xmmword ptr [rdx] ; move the 4 f32's at the address contained in rdx into register xmm1
addps       xmm0, xmm1              ; add the values and store in xmm0
```

and an equivalent sequence where we skip the second `MOVAPS` and pass the address straight to the `ADDPS` instruction

```nasm
movaps      xmm0, xmmword ptr [rcx] ; move the 4 f32's at the address contained in rcx into register xmm0
addps       xmm0, xmmword ptr [rdx] ; add the 4 f32's at the address contained in rdx and store in xmm0
```

Addresses passed as argument this way have to be aligned.

When Intel release their next micro-architectures sandy-bridge it included VEX instruction encoding. This is a second form of all existing instructions that allowed them to accept unaligned memory arguments.

```nasm
vmovups      xmm0, xmmword ptr [rcx] ; move the 4 f32's at the address contained in rcx into register xmm0
vmovups      xmm1, xmmword ptr [rdx] ; move the 4 f32's at the address contained in rdx into register xmm1
vaddps       xmm0, xmm0, xmm1        ; add the values and store in xmm0
```

and

```nasm
vmovups      xmm0, xmmword ptr [rcx]        ; move the 4 f32's at the address contained in rcx into register xmm0
vaddps       xmm0, xmm0, xmmword ptr [rdx]  ; add the 4 f32's at the address contained in rdx and store in xmm0
```
are equivalent sequences and have no restrictions on alignment. The prefix `v` on all instruction signifies the VEX encoding.

In Rust anytime you enable AVX or higher using `target-feature` or `target-cpu` it will encode all vector instructions using VEX (technically if you enable AVX512 you get EVEX encoding but that's another tangent).

## Arm V8

There is one load instruction for SIMD on Arm V8 `LDR` (**L**oa**D** **R**egister). Unfortunately the question of can this instruction handle unaligned address is complicated. Whether an exception is generated for unaligned address is controlled at runtime by the value in a special CPU register. The value in this register can't actually be read or written by user code, so unless running on bare metal it's not possible to affect this or branch on it.

```rust
pub unsafe fn aligned_load_simd(input: &[f32]) -> float32x4_t {
    let input_ptr = input.as_ptr() as *const float32x4_t;
    input_ptr.read()
}

pub unsafe fn unaligned_load_simd(input: &[f32]) -> float32x4_t {
    let input_ptr = input.as_ptr() as *const float32x4_t;
    input_ptr.read_unaligned()
}
```

Regardless of exactly which one we choose, when we target an aarch64 platform we get the following for `aligned_load_simd`:
```nasm
example::aligned_load_simd:
        ldr     q0, [x0]
```

What happens for the unaligned load depends on the what the compiler can assume about the target. For example if we use `--target aarch64-unknown-linux-gnu` the compiler can assume that unaligned loads will not generate an exception.

```nasm
example::unaligned_load_simd:
        ldr     q0, [x0]
```

However when the compiler can't know ahead of time if alignment exceptions are enabled, such as using `--target aarch64-unknown-none`, it has to play it safe. It will move all four `f32` values into proper alignment on the stack, before loading them into our SIMD register.

```nasm
example::unaligned_load_simd:
        sub     sp, sp, #16
        ldp     w10, w9, [x0, #8]
        bfi     x10, x9, #32, #32
        str     x10, [sp, #8]
        ldp     w10, w9, [x0]
        bfi     x10, x9, #32, #32
        str     x10, [sp]
        ldr     q0, [sp], #16
```

It is possible to explicitly tell the compiler to allow unaligned access. If we change to `--target aarch64-unknown-none -C target-feature=-strict-align` we get back to:

```nasm
example::unaligned_load_simd:
        ldr     q0, [x0]
```

[Example](https://rust.godbolt.org/z/YM77xf)

*Insert Benchmarks*

The range of ARM targets is incredibly large. We can see high end ARM server chips having the same properties as the Intel chips, but chips used in phone handsets and embedded devices still have a penalty on unaligned SIMD memory operations.

https://stackoverflow.com/questions/26701262/how-to-check-the-existence-of-neon-on-arm

