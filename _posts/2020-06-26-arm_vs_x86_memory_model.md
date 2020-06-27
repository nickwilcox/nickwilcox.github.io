---
title: Examining ARM vs X86 Memory Models with Rust
categories:
  - blog
tags:
  - ARM
  - X86
  - Atomics
  - Rust
---

With Apple's recent announcement that they are moving away from Intel X86 CPU's to their own ARM CPU's for future laptops and desktops I thought it would be a good time to take a look at the some differences that can affect systems programmers working in Rust. 

One of the key areas where ARM CPU's differ from X86 is their memory model. This article will take a look at what a memory model is and how it can cause code to be correct on one CPU but cause race conditions on another.

## Memory Models

The way loads and stores to memory interact between multiple threads on a specific CPU is called that architecture's Memory Model.

Depending on the memory model of the CPU, multiple writes by one thread may become visible to another thread in a different order to the one they were issued in. 

The same is true of a thread issuing multiple reads. A thread issuing multiple reads may receive "snapshots" of global state that represent points in time ordered differently to the order of issue.

Modern hardware needs this flexibility to be able to maximize the throughput of memory operations. While CPU clock rates and core counts have been increasing with each new CPU iteration, memory bandwidth has struggled to keep up. Moving data from memory to operate on is often the bottle neck in the performance of applications.

If you've never written multi-threaded code, or only done so using higher level synchronization primitives such as `std::sync::Mutex`, you've probably never been exposed to the details of the memory model. This is because the CPU, despite whatever reordering it's memory model allows it to perform, always presents a consistent view of memory to the current thread.

If we look at the below snippet of code that writes to memory and then reads the same memory straight back, we will always get the expected value of `58` back when we read. There is never the case that we'd read some stale value from memory.

```rust
pub unsafe fn read_after_write(u32_ptr: *mut u32) {
    u32_ptr.write_volatile(58);
    let u32_value = u32_ptr.read_volatile();
    println!("the value is {}", u32_value);
}
```
*I'm using volatile operations because if I used normal pointer operations the compiler is smart enough to skip the memory read and just prints the value `58`. 
Volatile operations stop the compiler from reordering or skipping our memory operation. However they have no affect on hardware.*

Once we introduce multiple threads, we're now exposed to the fact that the CPU may be reordering our memory operations.

We can examine the snippet below in a multi-threaded context:

```rust
pub unsafe fn writer(u32_ptr_1: *mut u32, u32_ptr_2: *mut u32) {
    u32_ptr_1.write_volatile(58);
    u32_ptr_2.write_volatile(42);
}

pub unsafe fn reader(u32_ptr_1: *mut u32, u32_ptr_2: *mut u32) -> (u32, u32) {
    (u32_ptr_1.read_volatile(), u32_ptr_2.read_volatile())
}
```

If we initialize the contents of both pointers to `0`, and then run each function in a different thread, we can list the possible outcomes for the reader. We know that there is no synchronization, but based on our experience with single threaded code we think the possible return values are `(0, 0)`, `(58, 0)` or `(58, 42)`. But the possibility of hardware reordering of memory writes affecting multi-threads means that there is a fourth option `(0, 42)`.

You might think there are more possibilities due to the lack of synchronization. But all hardware memory models guarantee that aligned loads and store up to the native word size are atomic (u32 or a 32-bit CPU, u64 on a 64-bit CPU). If we changed one of our writes to `0xFFFF_FFFF`, the read will only ever see the old value or the new value. It will never see a partial value like `0xFFFF_0000`.

If the details of the CPU's memory model are hidden away when using regular memory accesses, it seems like we would have no way to control it in multi-threaded programs where it affects program correctness.

Luckily Rust provides as with the `std::sync::atomic` module containing types that gives us the control we need. We use these types to specify exactly the memory ordering requirements our code needs. We trade performance for correctness. We place restrictions on what order the hardware can perform memory operations, taking away any bandwidth optimizations the hardware would want to perform.

When working with the `atomic` module, we don't worry about the actual memory models of individual CPU architectures. Instead the operation of the `atomic` module works on an abstract memory model that's CPU agnostic. Once we've expressed our requirements on the loads and stores using this Rust memory model, the compiler does the job of mapping to the memory model of the target CPU.

The requirements we specify on each operation takes the form of what reordering we want to allow (or deny) on the operation. The orderings form a hierarchy, with each level placing more restrictions the CPU. For example `Ordering::Relaxed` means the CPU is free to perform any reordering it wants. `Ordering::Release` means that a store can only complete after all proceeding stores have finished.

Let's look at how atomic memory writes are actually compiled, compared to a regular write.

```rust
use std::sync::atomic::*;

pub unsafe fn test_write(shared_ptr: *mut u32) {
    *shared_ptr = 58;
}

pub unsafe fn test_atomic_relaxed(shared_ptr: &AtomicU32) {
    shared_ptr.store(58, Ordering::Relaxed);
}

pub unsafe fn test_atomic_release(shared_ptr: &AtomicU32) {
    shared_ptr.store(58, Ordering::Release);
}

pub unsafe fn test_atomic_consistent(shared_ptr: &AtomicU32) {
    shared_ptr.store(58, Ordering::SeqCst);
}
```

If we look at the [X86 assembly](https://godbolt.org/z/uVQM8T) for the above code, we see the first three functions produce identical code. It's not until the stricter `SeqCst` ordering that we get a different instruction being produced.

```nasm
example::test_write:
        mov     dword ptr [rdi], 58
        ret

example::test_atomic_relaxed:
        mov     dword ptr [rdi], 58
        ret

example::test_atomic_release:
        mov     dword ptr [rdi], 58
        ret
        
example::test_atomic_consistent:
        mov     eax, 58
        xchg    dword ptr [rdi], eax
        ret
```
The first two orderings use the **`MOV`** (**MOV**e) instruction to write the value to memory. Only the strictest ordering produces a different instruction, **`XCHG`** (atomic e**XCH**an**G**), to a raw pointer write.

We can compare that to the [ARM assembly](https://godbolt.org/z/wWQo8P).

```nasm
example::test_write:
        mov     w8, #58
        str     w8, [x0]
        ret

example::test_atomic_relaxed:
        mov     w8, #58
        str     w8, [x0]
        ret

example::test_atomic_release:
        mov     w8, #58
        stlr    w8, [x0]
        ret
        
example::test_atomic_consistent:
        mov     w8, #58
        stlr    w8, [x0]
        ret
```

In contrast we can see there is a difference once we hit the release ordering requirement. The raw pointer and relaxed atomic store use **`STR`** (**ST**ore **R**egister) while the release and sequential ordering uses the instruction **`STLR`** (**ST**ore with re**L**ease **R**egister). *The **`MOV`** instruction is this disassembly is moving the constant `58` into a register, it's not a memory operation.*

We should be able to see the risk here. The mapping between the theoretical Rust memory model and the X86 memory model is more forgiving to programmer error. It's possible for us to write code that is wrong with respect to the abstract memory model, but still have it produce the correct assembly code and work correctly on some CPU's.

## Writing a Multi-Threaded Program using Atomic Operations

The program we'll be exploring builds upon the concept of storing a pointer value being atomic across threads. One thread is going to perform some work using a mutable object it owns. Once it's finished that work it's going to publish that work as an immutable shared reference, using an atomic pointer write to both signal the work is complete and allow reading threads to use the data.

## The X86 Only Implementation

If we really want to test how forgiving the X86's memory model is, we can write multi-threaded code that skips any use of the `std::sync::atomic` module. I want to stress this is not something you should ever actually consider doing. In fact this code is probably undefined behavior. This is an learning exercise only.

```rust
pub struct SynchronisedSum {
    shared: UnsafeCell<*const u32>,
    samples: usize,
}

impl SynchronisedSum {
    pub fn new(samples: usize) -> Self {
        assert!(samples < (u32::MAX as usize));
        Self {
            shared: UnsafeCell::new(std::ptr::null()),
            samples,
        }
    }

    pub fn generate(&self) {
        // do work on data this thread owns
        let data: Box<[u32]> = (0..self.samples as u32).collect();

        // publish to other threads
        let shared_ptr = self.shared.get();
        unsafe {
            shared_ptr.write_volatile(data.as_ptr());
        }
        std::mem::forget(data);
    }

    pub fn calculate(&self, expected_sum: u32) {
        loop {            
            // check if the work has been published yet
            let shared_ptr = self.shared.get();
            let data_ptr = unsafe { shared_ptr.read_volatile() };
            if !data_ptr.is_null() {
                // the data is now accessible by multiple threads, treat it as an immutable reference.
                let data = unsafe { std::slice::from_raw_parts(data_ptr, self.samples) };
                let mut sum = 0;
                for i in (0..self.samples).rev() {
                    sum += data[i];
                }

                // did we access the data we expected?
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

If I run the test on an Intel CPU I get:
```
running on x86_64
all iterations passed
```
If I run it on an ARM CPU with two cores I get:
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

Correct functioning of our pattern requires that all the "work" we're doing is in the correct state in memory, before we perform the final write to the shared pointer to publish it to other threads.

Where the memory model of ARM differs from X86 is that ARM CPU's will re-order writes relative to other writes, whereas X86 will not. So the calculate thread can see a non-null pointer and start reading values from the slice before they've been written.

For most of the memory operations in our program we want to give the CPU the freedom to re-arrange operations to maximize performance. We only want to specify the minimal constraints necessary to ensure correctness.

In the case of our `generate` function we want the values in the slice to be written to memory in whatever order gives us the most speed. But all writes must be complete before we write our value to the shared pointer.

The opposite is true on the `calculate`. We have a requirement the values we read from the slice memory are from at least the same point in time as value of the shared pointer. Although those instructions won't be issued until the read of the shared pointer has completed, we need the make sure that we're not getting values from a stale cache.

## The Correct Version

In order to ensure correctness of our code the write to the shared pointer must have release ordering, and because of the read order requirements in `calculate` we use acquire ordering.

Our initialization of the data doesn't change, neither does our sum code, we want to give the CPU the freedom to perform that however is most efficient.

```rust
struct SynchronisedSumFixed {
    shared: AtomicPtr<u32>,
    samples: usize,
}

impl SynchronisedSumFixed {
    fn new(samples: usize) -> Self {
        assert!(samples < (u32::MAX as usize));
        Self {
            shared: AtomicPtr::new(std::ptr::null_mut()),
            samples,
        }
    }

    fn generate(&self) {
        // do work on data this thread owns
        let mut data: Box<[u32]> = (0..self.samples as u32).collect();

        // publish (aka release) this data to other threads
        self.shared.store(data.as_mut_ptr(), Ordering::Release);

        std::mem::forget(data);
    }

    fn calculate(&self, expected_sum: u32) {
        loop {
            let data_ptr = self.shared.load(Ordering::Acquire);

            // when the pointer is non null we have safely acquired a reference to the global data
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

If we run the updated version using `AtomicPtr<u32>` on our ARM cpu we get
```
running on aarch64
all iterations passed
```

## Choice of Ordering Matters

Using the `atomic` module still requires care when working across multiple CPU's. As we saw from looking at the X86 vs ARM assembly outputs, if we replace `Ordering::Release` with `Ordering::Relaxed` on our `store` we'd be back to a version that worked correctly on x86 but failed on ARM. It's especially required working with `AtomicPtr` to avoid undefined behavior when eventually accessing the value pointed at.

## Further Reading

This is just a brief introduction to memory models, hopefully it's clear to someone unfamiliar with the topic.

* [Details on the ARM V-8 Memory Model](https://developer.arm.com/docs/100941/0100/the-memory-model)
* [Details of Intel X86 Memory Model](https://software.intel.com/content/www/us/en/develop/download/intel-64-and-ia-32-architectures-sdm-volume-3a-system-programming-guide-part-1.html)
* [The Rust `atomic` module ordering reference](https://doc.rust-lang.org/std/sync/atomic/enum.Ordering.html)

I think my first introduction to lock-free programming was this [article](https://docs.microsoft.com/en-au/windows/win32/dxtecharts/lockless-programming?redirectedfrom=MSDN). It may not seem relevant because the details cover C++, the PowerPC CPU in the Xbox360, and Windows APIs. But it's still a good explanation of the principles. Also this paragraphs from the opening still hold ups:

> Lockless programming is a valid technique for multithreaded programming, but it should not be used lightly. Before using it you must understand the complexities, and you should measure carefully to make sure that it is actually giving you the gains that you expect. In many cases, there are simpler and faster solutions, such as sharing data less frequently, which should be used instead.

## Conclusion

Hopefully we've learnt about a new aspect of systems programming that will become increasingly important as ARM chips become more common. Ensuring correctness of atomic code has never been easy but it gets harder when working across different architectures with varying memory models.

## Sources

All the source code for this article can be found [on github](https://github.com/nickwilcox/blog_memory_model)

### Discussion

Link to the [discussion on Reddit](https://www.reddit.com/r/rust/comments/hgkgg2/examining_arm_vs_x86_memory_models_with_rust/)
