---
title: Target Feature vs Target CPU
categories:
  - blog
tags:
  - Optimization
  - Rust
---


So far the loops we've looked at have all dealt with loading, processing and storing adjacent elements in our slices.

This has been traditional use case for SIMD. If you tried to operate of values that aren't stored sequentially the CPU time spent gathering the non-adjacent data into SIMD registers in the loading phase would nullify the performance gains from the processing stage.

To expand the opportunities for SIMD optimization Intel added the `VPGATHER` group of instructions when creating the AVX2 instruction family. These instructions takes a SIMD register containing multiple addresses and loads the value at the address into the corresponding element of the output SIMD register.

An example of a workload that could benefit from faster gathering is converting an indexed image. Indexed images are when each pixel doesn't directly contain a colour but is an index into a color palette. If we wanted to convert from an indexed image to a normal image, we simple replace the index by the value looked up in the palette.

```rust
pub fn indexed_to_rgba32(input: &[u8], palette: &[u32], output: &mut [u32]) {
    let pallete = &palette[0..256];
    for (y, index) in output.iter_mut().zip(input.iter()) {
        *y = pallete[*index as usize];
    }
}
```

So if we take the lessons from the previous article and apply the `target-feature` option to our compiler command line.

https://godbolt.org/z/JZ2jNh

We don't see any sign of SIMD in the output.

If we take a look at Agner Fog's excellent [Instruction Table](https://www.agner.org/optimize/instruction_tables.pdf) document that gives the latency (number of CPU cycles it takes to retire) for each instruction across various Intel and AMD models. We can 

The CPU's that support AVX2 include Broadwell, Haswell, Skylake, and Coffee Lake from Intel and Excavator and Ryzen from AMD. The latency of `VPGATHERQD` ranges from 13 down to 2.

Given that on some hardware using the instruction might be slower than the simpler code, the compiler has chosen not to vectorize this loop.

So the `target-feature` option that seemed able give us fine grained control over the instructions generated is no longer enough.

The obvious answer seem to be the `target-cpu` flag. If we compile again with `target-cpu=skylake`, and change the compilers cost model so that `VPGATHER` instructions are cheaper.

https://godbolt.org/z/4dvNiF

We can now see the compiler has generated radically different code. It's vectorized and unrolled the loop, so we can see multiple instances of `VPGATHERDQ`. Each iteration of the assembler loop corresponds to 64 iterations of the original loop.

Unfortunately there is no equivalent of `#[target_feature(enable = "...")]` and `is_x86_feature_detected!("...")` we can use in our code to compile multiple variants of our functions and switch at runtime.

The `target-cpu` option doesn't just affect compilation of Rust. It can also affect intrinsics.

When SIMD intrinsics functions were first introduced to C++ compilers each one was documented as mapping to a specific CPU instruction (there were a few exceptions). All the C++ compilers follow Intel's naming for their instrinsic functions.

When implementing the intrinsics in Rustc, the compiler authors followed Intel's naming, but mapped them to high level operations in LLVM (LLVM is the Rust compiler's backend). This leaves the compiler free to map to whatever instruction it thinks will give the optimal performance.

There is a strange situation where the x86 specific intrinsics are actually implemented by rustc as platform independent LLVM intrinsics. Because they are implemented as LLVM intrinsics they are subject to the compilers cost model when deciding what instructions to generate.

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

This is a contrived example where we want to shuffle some data around within a 256bit AVX2 variable. If we consult the Intel Intrinsics Guide we see that the `_mm256_shuffle_epi8` intrinsics should generate the `VPSHUFB` instruction.

However when we compile we see that instead of a single instruction the compiler has generated a sequence of two shuffles: `VPSHUFHW` and `VPSHUFHD` to implement our function.

https://godbolt.org/z/befPiu

If we again check the Instruction Table we see that on some AMD hardware the `VPSHUFB` instruction had a high latency so the compiler has been conservative and replaced this potentially expensive instruction with two cheaper instructions.

If we add a target CPU flag to our compiler options, this time `haswell` which is the first Intel CPU supporting AVX2.

https://godbolt.org/z/6Z-AcD

We get only our single desired `VPSHUFB` instruction generated.

## Conclusion

Setting the `target-cpu` flag does more than simply enabling CPU features. It changes the compiler's instruction cost model which can cause it to generate drastically different code.

This is most obvious around AVX2, which is recent enough that early implementations have different instructions costs than the more recent.

Unfortunately there is no convenient solution in Rust for multi-versioning functions to target different CPU micro-architectures.