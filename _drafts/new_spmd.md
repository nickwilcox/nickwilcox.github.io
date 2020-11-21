---
title: Untitled
categories:
  - blog
tags:
  - Optimisation
  - Rust
---

## Branching

The first challenge we're going to throw at the compiler is branching. If different iterations of the loop execute different instructions, how can SIMD be used to gain performance.

```rust
pub fn branching(input: &[f32], output: &mut [f32]) {
    for (y, x) in output.iter_mut().zip(input.iter()) {
        if *x > 0.0 {
            *y = x * 5.0;
        } else {
            *y = x + 8.0;
        }
    }
}
```

### SSE 2
```nasm
movups  xmm0, xmmword ptr [rdi + 4*rsi]
xorps   xmm3, xmm3
cmpltps xmm3, xmm0
movaps  xmm4, xmmword ptr [rip + .LCPI0_0]
movaps  xmm5, xmm0
addps   xmm5, xmm4
movaps  xmm6, xmmword ptr [rip + .LCPI0_1]
mulps   xmm0, xmm6
andps   xmm0, xmm3
andnps  xmm3, xmm5
orps    xmm3, xmm0
```

There are no branching instructions produced by the compiler, but there is a **`addps`** and **`mulps`** along with some other operations.

What the compiler is doing is executing both sides of the `if` statement for every iteration, and then *blending* the two different outputs into the single final output using a sequence of bitwise logical operations.

The first step is performance four less-than comparisons and produce a mask using the **`cmpltps`** instruction.

```
  ┌───────────────────────────────┐
  │  3.0  │ -1.0  │  4.0  │  5.0  │
  └───────────────────────────────┘

  ┌───────────────────────────────┐
  │  0.0  │  0.0  │  0.0  │  0.0  │
  └───────────────────────────────┘
  
  ┌───────────────────────────────────────────────────────────┐
  │  0x00000000  │  0xFFFFFFFF  │  0x00000000  │  0x00000000  │
  └───────────────────────────────────────────────────────────┘
```

The output is a integer SIMD values, where each individual value is either all ones `0xFFFFFFF` or all zeroes `0x00000000` depending on the comparison results.

When we have a vector in this format we refer to it as a *mask*.

This mask is what controls the blend between the output of the addition and the output of the multiply.

The blend itself uses the bitwise logical instructions **`andps`**, **`andnps`**, and **`orps`**.

### AVX

```nasm
vmovups     ymm4, ymmword ptr [rdi + 4*rsi + 32]
vcmpltps    ymm7, ymm0, ymm4
vaddps      ymm11, ymm3, ymm4
vmulps      ymm3, ymm3, ymm4
vblendvps   ymm3, ymm11, ymm3, ymm7
```

AVX has an instruction called **`blendvps`** that encapsulated the three steps that had to be taken by the SSE2 code to blend the addition and the multiplication together.

### AVX512

```nasm
vmovups     zmm3, zmmword ptr [rdi + 4*rsi]
vcmpltps    k1, zmm0, zmm3
vaddps      zmm7, zmm3, zmm1
vmulps      zmm7 {k1}, zmm3, zmm2
```

AVX512 introduced the concept of *mask registers*, and added the capability of any instruction to support blending when it's performed.

If we compare AVX512 to AVX we see that `cmpltps` is putting the result in a mask register `k1` instead of the general purpose SIMD register `ymm7`.

The add operation is performed unmasked. Then the multiply operations is performed with a mask (note the `zmm7 {k1}` syntax used in the `vmulps` instruction) so it will only output to the correct elements inside the SIMD value.


### Performance Comparison

## Input Dependant Loops

This is another way of saying our loop contains a second inner loop whose number of iterations depends on the input.

```rust
pub fn looping(input: &[f32], output: &mut [f32]) {
    for (y, x) in output.iter_mut().zip(input.iter()) {
        *y = *x;
        while *y < 1_000.0 {
            *y = *y + 20.0;
        }
    }
}
```

No level of instruction set would result in auto-vectorization of this type of loop.

## Gather

So far all our memory operations have been sequential. We iterate over our two arrays in sequential lockstep.

If we add a level of indirection, so that one of our inputs is a list of offsets into a third slice that we want to access and write sequentially to the output. 

Based on the first article in the series we know that the compiler is not going to vectorize a loop containing a slice access unless it can "prove" that it won't panic. In order to work around this we'll use the unsafe function `get_unchecked()` and mark our function as `unsafe`.

```rust
pub unsafe fn gather(input_indices: &[i32], input: &[f32], output: &mut [f32]) {
    for (y, index) in output.iter_mut().zip(input_indices.iter()) {
        let x = input.get_unchecked(*index as usize);
        *y = *x;
    }
}
```

### SSE


### AVX2

AVX2 included gather instructions, in this case we'd be looking to **`vgatherdps`** due to using `i32` offsets. Unfortunately the compiler didn't vectorize this loop.

### AVX512

```nasm
vpmovsxdq       zmm2, ymmword ptr [rdi + 4*rsi]
vpsllq          zmm2, zmm2, 2
vpaddq          zmm2, zmm0, zmm2
kxnorw          k1, k0, k0
vpgatherqd      ymm3 {k1}, ymmword ptr [zmm2]
```

Surprisingly the AVX512 targeted compilation did produce usage of **`vgatherdps`** that we hoped for when using AVX2.

### Performance

## Scatter

Scatter is the opposite operation to gather. We write our output value to different offsets in the output slice.

```rust
pub unsafe fn scatter(output_indices: &[i32], input: &[f32], output: &mut [f32]) {
    for (x, index) in input.iter().zip(output_indices.iter()) {
        let y = output.get_unchecked_mut(*index as usize);
        *y = *x;
    }
}
```

### AVX512

```nasm
vpmovsxdq       zmm1, ymmword ptr [rdi + 4*rsi]
vpsllq          zmm1, zmm1, 2
vpaddq          zmm1, zmm0, zmm1
kxnorw          k1, k0, k0
vpscatterqd     ymmword ptr [zmm1] {k1}, ymm3
```

AVX512 is the only instruction family with scatter instructions and does vectorize the loop to use them

