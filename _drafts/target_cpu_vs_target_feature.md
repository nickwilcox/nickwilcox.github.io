---
title: Target Feature vs Target CPU
categories:
  - blog
tags:
  - Optimization
  - Rust
---

In the [previous article]({% post_url 2020-05-29-autovec2 %}) on auto-vectorization we looked at the different SIMD instruction set families on X86-64. We saw how he `target-feature` compiler flag and `#[target_feature(enable = "..")]` attribute gave us more control over the instructions used in the generated assembly.

There is a related compiler flag `target-cpu` we didn't touch on, so it's worth taking a look at how it affects the generated code.

#### TL;DR
Setting the `target-cpu` flag on the compiler does more than simply enabling CPU features. It changes the compiler's instruction cost model which can cause it to generate drastically different code.

## The Benchmark Function
So far the loops we've looked at have all dealt with loading, processing and storing adjacent elements in our slices.

This has been traditional use case for SIMD. If you tried to operate of values that aren't stored sequentially in memory the time spent gathering the data into SIMD registers in the loading phase would nullify the performance gains from the processing stage.

To expand the opportunities for SIMD optimization Intel added the `VPGATHER` group of instructions when creating the AVX2 instruction family. These instructions takes a SIMD register containing multiple addresses and loads the value at the address into the corresponding element of the output SIMD register.

An example of a workload that could benefit from faster gathering is converting an indexed image. Indexed images are when each pixel doesn't directly contain a colour but is an index into a color palette. If we wanted to convert from an indexed image to a normal image, we simple replace the index by the value looked up in the palette.

```rust
pub type RGBA32 = u32;
pub fn indexed_to_rgba32(input: &[u8], palette: &[RGBA32], output: &mut [RGBA32]) {
    let palette = &palette[0..256];
    for (y, index) in output.iter_mut().zip(input.iter()) {
        *y = palette[*index as usize];
    }
}
```

So if we take the lessons from the previous article and apply the `target-feature` option to our compiler command line to allow the compiler to use instructions from AVX2 we get https://godbolt.org/z/JZ2jNh :

```nasm
.LBB0_9:
    movzx   eax, byte ptr [rdi + rcx]
    mov     eax, dword ptr [rdx + 4*rax]
    mov     dword ptr [r8 + 4*rcx], eax
    movzx   eax, byte ptr [rdi + rcx + 1]
    mov     eax, dword ptr [rdx + 4*rax]
    mov     dword ptr [r8 + 4*rcx + 4], eax
    movzx   eax, byte ptr [rdi + rcx + 2]
    mov     eax, dword ptr [rdx + 4*rax]
    mov     dword ptr [r8 + 4*rcx + 8], eax
    movzx   eax, byte ptr [rdi + rcx + 3]
    mov     eax, dword ptr [rdx + 4*rax]
    mov     dword ptr [r8 + 4*rcx + 12], eax
    add     rcx, 4
    cmp     r9, rcx
    jne     .LBB0_9
    test    r10, r10
    je      .LBB0_7
```

Unfortunately we don't see any sign of auto-vectorization in the output. The loop has been unrolled to execute four iterations at a time, but it uses four separate loads to get the values from the palette.

## CPU Micro-Architectures

To understand why this is happening we need a brief digression to explain some terms.

X86-64 is our CPU **architecture**. A specific CPU implementation of that architecture is called a **micro-architecture**. An architecture will have a base set to instructions all implementations must support, and families of optional instructions the implementation can choose to support. In a previous article I talked about optional instruction families such as SSE3, SSE4.1, AVX and AVX2. When we talk about a CPU supporting an optional instruction set family, we're more specifically talking about the micro-architecture supporting it.

Micro-architecture's use manufacturer designated code names. In recent times Intel has had Sandy Bridge, which was the first micro-architecture to support AVX instructions, followed later by Haswell which added AVX2, which was followed by Skylake. The code names can give an insight to the relationship between micro-architectures. Between Sandy Bridge and Haswell there was a small revision called Ivy Bridge, Broadwell was a similar small revision to Haswell.

Intel has moved away from marketing names such as i3, i5, i7 having any fixed relationship to micro-architecture. But broadly speaking an i7 will have a better micro-architecture than an i3 released at the same time.

An excellent resource for understanding the performance differences between micro-architectures is Agner Fog's [Instruction Tables](https://www.agner.org/optimize/instruction_tables.pdf) document. This document gives the latency (number of CPU cycles it takes to complete an instruction) for every instruction across various Intel and AMD micro-architectures. We can use these numbers to estimate if using a specific instruction is worthwhile when we multiple ways of implementing our code.

If you want to know *why* the micro-architectures have the behaviour they do, Agner also has his [Micro-Arhitecture Manual](https://www.agner.org/optimize/microarchitecture.pdf).

The micro-architectures in the document that support AVX2 are Broadwell, Haswell, Sky Lake, and Coffee Lake from Intel and Excavator and Zen from AMD. The latency of `VPGATHERQD` (the exact instruction we need for this function) ranges from 14 on Excavator down to only 2 on Sky Lake. We can see that newer micro-architecture don't just add support for new instructions or increase the overall performance, they can greatly improve the relative performance of how individual instructions are executed.

Given that on some hardware using the instruction might be slower than the simpler code that doesn't use SIMD gather, the compiler has chosen not to vectorize this loop.

So the `target-feature` option that seemed able give us fine grained control over the instructions generated is no longer enough.

## Specifying the Exact Micro-Architecture

The obvious answer seem to be the `target-cpu` flag. If we compile again with `target-cpu=skylake`, and change the compiler's cost model so that `VPGATHER` instructions are considered faster to execute we get https://godbolt.org/z/4dvNiF :

```nasm
.LBB0_7:
    vpmovzxbq       ymm0, dword ptr [rdi + rsi + 4]
    vpmovzxbq       ymm1, dword ptr [rdi + rsi]
    vpcmpeqd        xmm2, xmm2, xmm2
    vpgatherqd      xmm3, xmmword ptr [rdx + 4*ymm1], xmm2
    vpcmpeqd        xmm1, xmm1, xmm1
    vpgatherqd      xmm2, xmmword ptr [rdx + 4*ymm0], xmm1
    ; ... snip ...
```

We can now see the compiler has generated radically different code. It's vectorized and unrolled the loop, so we can see multiple instances of `VPGATHERQD`. Each iteration of the assembler loop corresponds to 64 iterations of the original loop.

## Benchmarking Results

If we benchmark the two compiler generated versions of the function along with a hard written version of the same function using the `` instrinsic function we get the following results. 

| CPU                            | `cpu-feature=+avx2` | `cpu-target=Skylake` | Intrinsics |
|--------------------------------|---------------------|----------------------|------------|
| Haswell (i5-4670K @ 3.4Ghz)    | 26 μs               | 44 μs                | ?? μs      |
| Zen 1 (AMD EPYC 7571 @ 2.1GHz) | 39 μs               | 92 μs                | 72 μs      |
| Skylake (i7-8650U @ 1.90GHz)   | 28 μs               | 20 μs                | 15 μs      |

The compilers decision holds up. On all micro-architectures apart from Skylake it's slower to vectorize the loop and use the `VPGATHERQD` instruction.

We also see the same result from the previous article where the compilers generated AVX2 is not as fast as manually writing it using intrinsic functions.

## Targeting Multiple Micro-Architectures

In the previous articles we saw how `#[target_feature(enable = "...")]` and `is_x86_feature_detected!("...")` can be used in our code to compile multiple variants of our functions and switch at runtime. 

Unfortunately there is no equivalent for generating multiple variants of our functions to target different micro-architectures.

## The Effect on Explicit SIMD

The `target-cpu` option doesn't just affect compilation and auto-vectorization of scalar Rust. It can also affect explicit SIMD code written using intrinsics. This might be unexpected as the Rust documentation for x86-64 intrinsics links to Intel's documentation which will usually list the exact instruction to be generated.

However when implementing the Intel SIMD intrinsics in Rustc, the compiler authors followed Intel's naming and semantics, but actually mapped them to high level operations in LLVM (LLVM is the Rust compiler's backend). This leaves LLVM free to map to whatever instruction it thinks will give the optimal performance.

We can see a concrete demonstration of this with the `_mm256_shuffle_epi8` intrinsic from AVX2. The [Rust documentation](https://doc.rust-lang.org/core/arch/x86_64/fn._mm256_shuffle_epi8.html) describes it's behavior and links to [Intel's documentation](https://software.intel.com/sites/landingpage/IntrinsicsGuide/#text=_mm256_shuffle_epi8) which states that it maps to the `VPSHUFB` instruction.

```rust
use std::arch::x86_64::*;

#[target_feature(enable = "avx2")]
pub unsafe fn do_shuffle(input: __m256i) -> __m256i {
    const SHUFFLE_CONTROL_DATA: [u8; 32] = [
        0x0E, 0x0F, 0x0E, 0x0F,
        0x0E, 0x0F, 0x0E, 0x0F,
        0x0E, 0x0F, 0x0E, 0x0F,
        0x0E, 0x0F, 0x0E, 0x0F,
        0x0E, 0x0F, 0x0E, 0x0F,
        0x0E, 0x0F, 0x0E, 0x0F,
        0x0E, 0x0F, 0x0E, 0x0F,
        0x0E, 0x0F, 0x0E, 0x0F,
    ];
    let shuffle_control = _mm256_loadu_si256(SHUFFLE_CONTROL_DATA.as_ptr() as *const __m256i);
    _mm256_shuffle_epi8(input, shuffle_control)
}
```

However when we compile we see that instead of a single instruction the compiler has generated a sequence of two shuffles: `VPSHUFHW` and `VPSHUFHD` to implement our function.

https://godbolt.org/z/befPiu

```nasm
example::do_shuffle:
  mov       rax, rdi
  vpshufhw  ymm0, ymmword ptr [rsi], 239
  vpshufd   ymm0, ymm0, 170
  vmovdqa   ymmword ptr [rdi], ymm0
  vzeroupper
  ret
```

If we add a target CPU flag to our compiler options, this time picking `haswell` we get:

https://godbolt.org/z/6Z-AcD

```nasm
example::do_shuffle:
  mov       rax, rdi
  vmovdqa   ymm0, ymmword ptr [rsi]
  vpshufb   ymm0, ymm0, ymmword ptr [rip + .LCPI0_0]
  vmovdqa   ymmword ptr [rdi], ymm0
  vzeroupper
  ret
```

We get only our single target `VPSHUFB` instruction generated.

## Conclusion

Setting the `target-cpu` flag does more than simply enabling CPU features. It changes the compiler's instruction cost model which can cause it to generate drastically different code.

This is most obvious around AVX2, which is recent enough that early implementations have different instructions costs than the more recent micro-architectures.

Unfortunately there is no convenient solution in Rust for multi-versioning functions to target different CPU micro-architectures within a single executable.

<!-- https://godbolt.org/z/UYtPvf  -->