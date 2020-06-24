---
title: Untitled
categories:
  - blog
tags:
  - ARM
  - X86
  - Atomics
  - Rust
---

# ARM and X86

One of the areas where ARM cpu's differ from X86 is their memory model. This article will take a look at what a memory model is and how it can cause code to be correct on one CPU but cause race conditions on another.

## Basic Atomic Operations
On modern CPU's aligned loads and store up to the native word size are atomic. This means that on a 64bit CPU like Apple's new ARM processors or a desktop X86 processor, when one core stores a `u8`, `u16`, `u32`, `u64` or `*T`, other cores will only ever read the whole value. 

```rust
unsafe fn thread_1(shared_ptr: *mut u32) {
    std::ptr::write_volatile(shared_ptr, 0xFFFF_FFFF);
}

unsafe fn thread_2(shared_ptr: *const u32) {
    let shared_value = std::ptr::read_volatile(shared_ptr);
    println!("shared value {}", shared_value);
}
```

If the value in `shared_ptr` is initialized as `0`, then when `thread_2` runs it is guaranteed to only ever read `0` or `0xFFFF_FFFF`. It will never see a half written value like `0xFFFF_0000`.

*TODO* explain volatiles or get rid of them

## ??
The pattern we'll be exploring builds upon the concept of storing a pointer being atomic across threads. One thread is going to perform some work using a mutable object it owns. Once it's finished that work it's going to publish that work as an immutable shared reference, using a pointer write.

## Initial Implementation

```rust
pub struct SynchronisedSum {
    shared: UnsafeCell<*const u32>,
    samples: usize,
}

impl SynchronisedSum {
    pub fn new(samples: usize) -> Self {
        assert!((samples as u32) <= u32::MAX);
        Self {
            shared: UnsafeCell::new(std::ptr::null()),
            samples,
        }
    }

    pub fn generate(&self) {
        let data: Box<[u32]> = (0..self.samples as u32).collect();

        let shared_ptr = self.shared.get();
        unsafe {
            shared_ptr.write_volatile(data.as_ptr());
        }
        std::mem::forget(data);
    }
}
```

```rust
impl SynchronisedSum {
    pub fn calculate(&self, expected_sum: u32) {
        loop {
            let shared_ptr = self.shared.get();
            let data_ptr = unsafe { shared_ptr.read_volatile() };

            if !data_ptr.is_null() {
                let data = unsafe { std::slice::from_raw_parts(data_ptr, self.samples) };
                let mut sum = 0;
                for i in (0..self.samples).rev() {
                    sum += data[i];
                }
                assert_eq!(sum, expected_sum);
                break;
            }
        }
    }
}
```

The function that calculates the sum of the array starts by executing a loop that reads the value of the shared pointer. Because of the atomic store guarantee we know that `read_volatile()` will only ever return `null` or a pointer to our `u32` slice. We simply keep looping until the generate thread has finished and published it's work. Once it's published we can read it and calculate the sum of all elements.

## Testing the Code

As a simple test we're going to run two threads simultaneously, one to generate the values and another to calculate the sum. Both threads exit after performing their work and we'll wait for both of them to finish using `join`.

```rust
pub fn main() {
    print_arch();
    for i in 0..10_000 {
        let sum_generate = Arc::new(SynchronisedSum::new(512));
        let sum_calculate = Arc::clone(&sum_generate);
        let calculate_thread = thread::spawn(move || {
            sum_calculate.calculate(130816);
        });
        thread::sleep(std::time::Duration::from_millis(1));
        let generate_thread = thread::spawn(move || {
            sum_generate.generate();
        });

        calculate_thread
            .join()
            .expect(&format!("iteration {} failed", i));
        generate_thread.join().unwrap();
    }
    println!("all iterations passed");
}
```

If I run the test on an Intel laptop I get:
```
running on x86_64
all iterations passed
```
If I run on an ARM server I get:
```
running on aarch64
thread '<unnamed>' panicked at 'assertion failed: `(left == right)`
  left: `122824`,
 right: `130816`', src\main.rs:45:17
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
thread 'main' panicked at 'iteration 35 failed: Any', src\main.rs:128:9
```
The x86 processor was able to run the test successfully all 10,000 times, but the ARM processor failed on the 35th attempt.

## What Went Wrong
The way loads and stores to memory interact between multiple threads on a specific CPU is called that architectures **Memory Model**.

Depending on the memory model of the CPU, multiple writes by one thread may become visible to another thread in a different order to the one they were issued in. The same is true of a thread issuing multiple reads.

Correct functioning of our pattern requires that all the "work" we're doing is in the correct state in memory, before we perform the final write to the shared pointer to publish it to other threads.

Where the memory model of ARM differs from X86 is that ARM CPU's will re-order writes, whereas X86 will not.

For most of the memory operations in our program we want to give the CPU the freedom to re-arrange operations to maximize performance. We only want to specify the minimal constraints necessary to ensure correctness.

In the case of our `generate` function we want the values in the slice to be written to memory in whatever order gives us the most speed. But all writes must be complete before we write our value to the shared pointer.

The opposite is true on the `calculate`. We want the read of the shared pointer to happen before any reads of the array values.

## The Portable Version

We know that at key points in our program we need precise control over the memory model, regardless of what CPU we are running on. We cannot rely on regular reads and writes of values, or even `read_volatile` and `write_volatile`.

Luckily Rust provides as with the `std::sync::atomic` module containing types that gives us the control we need. We use these types to specify exactly the memory ordering requirements our code needs. 

The operation of the `atomic` module obeys an abstract memory model that's CPU agnostic. Once we've set our constraints on the loads and stores using the Rust memory model, the compiler does the job of mapping to the memory model of the target CPU.

An example of atomics in action compared to a regular memory write:
```rust
use std::sync::atomic::*;

pub unsafe fn test_write(shared_ptr: *mut u32) {
    *shared_ptr = 58;
}

pub unsafe fn test_atomic_write(shared_ptr: &AtomicU32) {
    shared_ptr.store(58, Ordering::Release);
}
```

[ARM assembly](https://godbolt.org/z/TvvVU3)
```nasm
example::test_write:
        mov     w8, #58
        str     w8, [x0]
        ret

example::test_atomic_write:
        mov     w8, #58
        stlr    w8, [x0]
        ret
```

[X86 assembly](https://godbolt.org/z/w8PBwn)
```nasm
example::test_write:
        mov     dword ptr [rdi], 58
        ret

example::test_atomic_write:
        mov     dword ptr [rdi], 58
        ret
```
We can see that on x86 both functions produce identical code and on ARM the compiler uses different instructions. The compiler knew that to give our write release ordering under the x86 memory model it didn't need to do anything different. But on ARM it has to use a special store instruction that has release ordering - `stlr` (**st**ore with re**l**ease **r**egister).

## Updated Version

In order to ensure correctness of our code our write to the shared pointer must have release ordering, this means that all preceding writes have completed before this write will occur.

Our initialization of the data doesn't change, we want to give the CPU the freedom to perform that however is most efficient.

```rust
struct SynchronisedSumFixed {
    shared: AtomicPtr<u32>,
    samples: usize,
}

impl SynchronisedSumFixed {
    fn new(samples: usize) -> Self {
        assert!((samples as u32) < u32::MAX);
        Self {
            shared: AtomicPtr::new(std::ptr::null_mut()),
            samples,
        }
    }

    #[inline(never)]
    fn generate(&self) {
        let mut data: Box<[u32]> = (0..self.samples as u32).collect();

        unsafe {
            self.shared.store(data.as_mut_ptr(), Ordering::Release);
        }
        std::mem::forget(data);
    }

    #[inline(never)]
    fn calculate(&self, expected_sum: u32) {
        loop {
            let data_ptr = unsafe { self.shared.load(Ordering::Acquire) };

            if !data_ptr.is_null() {
                let data = unsafe { std::slice::from_raw_parts(data_ptr, self.samples) };
                let mut sum = 0;
                for i in (0..self.samples).rev() {
                    sum += data[i];
                }
                assert_eq!(sum, expected_sum);
                break;
            }
        }
    }
}
```

If we run the update version using `AtomicPtr<u32>` on our ARM cpu we get
```
running on aarch64
all iterations passed
```

## Ordering Matters
Using `AtomicPtr<u32>` still requires care when working across multiple CPU's. If we replaced `Ordering::Release` with `Ordering::Relaxed` we'd be back to a version that worked correctly on x86 but failed on ARM.

## The Real World

This was a demonstration of code that works on x86 but fails on ARM due to reasons that might not be familiar to some programmers.

In the real work it takes more than a loop of 10,000 iterations to ensure correctness of code using atomics.

It's far better to design multi-threading code that avoids shared mutable state.

## Conclusion
