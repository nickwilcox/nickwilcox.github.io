---
title: Untitled
categories:
  - blog
tags:
  - Optimisation
  - Rust
---
ipso factum

## SIMD
The traditional approach when using SIMD by hand is to look for types where an instance 

A common example are types found in 3D applications such as 3D points, vectors and matrices.

```rust
#[derive(Copy, Clone)]
pub struct Vector3D {
    x: f32,
    y: f32,
    z: f32,
}
impl std::ops::Add for Vector3D {
    type Output = Vector3D;
    fn add(self, rhs: Vector3D) -> Self::Output {
        Vector3D {
            x: self.x + rhs.x,
            y: self.y + rhs.y,
            z: self.z + rhs.z,
        }
    }
}
impl std::ops::Mul for Vector3D {
    type Output = Vector3D;
    fn mul(self, rhs: Vector3D) -> Self::Output {
        Vector3D {
            x: self.x * rhs.x,
            y: self.y * rhs.y,
            z: self.z * rhs.z,
        }
    }
  }
```

If we wanted to optimise this we could replace the implementation with one that uses SIMD intrinsics.

```rust
use core::arch::x86_64::*;
#[derive(Copy, Clone)]
pub struct Vector3D {
    inner: __m128,
}
impl std::ops::Add for Vector3D {
    type Output = Vector3D;
    fn add(self, rhs: Vector3D) -> Self::Output {
        let inner = unsafe { _mm_add_ps(self.inner, rhs.inner) };
        Vector3D { inner }
    }
}
impl std::ops::Mul for Vector3D {
    type Output = Vector3D;
    fn mul(self, rhs: Vector3D) -> Self::Output {
        let inner = unsafe { _mm_mul_ps(self.inner, rhs.inner) };
        Vector3D { inner }
    }
}
```

It's not a coincedence that these 3D linear algebra types map well to SIMD instructions. It's one of the main design targets of the instructions. 


```rust
pub fn calculate_movement(position: Vector3D, velocity: Vector3D, delta_t: f32) -> Vector3D {
  position + velocity * delta_t;
}
```
### What are the limitations

## The SPMD-on-SIMD Approach

All the SIMD we looked at in the previous articles was about optimising loops. The general pattern is reduce the number of times we loop by handling multiple elements per iteration of the loop.

This might be clearer if we hand write a simple example.

```rust
pub fn simple_loop(input: &[f32], output: &mut [f32]) {
    for (y, x) in output.iter_mut().zip(input.iter()) {
        *y = x * 2.0;
    }
}
pub unsafe fn simple_loop_spmd_with_sse(input: &[f32], output: &mut [f32]) {
    let two = _mm_set1_ps(2.0);
    for (y, x) in output.chunks_exact_mut(4).zip(input.chunks_exact(4)) {
        let x128 = _mm_loadu_ps(y.as_ptr());
        let y128 = _mm_mul_ps(x128, two);
        _mm_storeu_ps(y.as_mut_ptr(), y128);
    }
}

#[cfg(target_feature = "avx2")]
pub unsafe fn simple_loop_spmd_with_avx2(input: &[f32], output: &mut [f32]) {
    let two = _mm256_set1_ps(2.0);
    for (y, x) in output.chunks_exact_mut(8).zip(input.chunks_exact(8)) {
        let x256 = _mm256_loadu_ps(y.as_ptr());
        let y256 = _mm256_mul_ps(x256, two);
        _mm256_storeu_ps(x.as_mut_ptr(), y256);
    }
}
```

If we look at the look at the loop statement, 

|        | Time for 100,000 Samples |
|--------|--------------------------|
| scalar | 33 μs                    |
| SSE2   | 12 μs                    |
| AVX    | 12 μs                    |

