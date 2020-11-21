---
title: Recipe for Calling Swift Closures from Asynchronous Rust Code
categories:
  - blog
tags:
  - Swift
  - Rust
  - Recipes
---

The purpose of this recipe is to integrate asynchronous Rust with idiomatic Swift code that uses completion handler blocks. 
All reference counting should be handled correctly without having the Swift application code manually manage memory.

An example usage would be writing your iOS UI using Swift and running a long operation in Rust without blocking the UI thread, but still being able to notifying the user when the operation is complete.

## Prerequisites

This recipe assumes a basic understanding of mixing Rust and Swift code. See this [tutorial](https://mozilla.github.io/firefox-browser-architecture/experiments/2017-09-06-rust-on-ios.html) for an introduction to the concepts.

## Rust Implementation
Let's start on the Rust side and build a C ABI compatible representation of our asynchronous completion callback.

```rust
#[repr(C)]
pub struct CompletedCallback {
    userdata: *mut c_void,
    callback: extern "C" fn(*mut c_void, bool),
}

unsafe impl Send for CompletedCallback {}

impl CompletedCallback {
    pub fn succeeded(self) {
        (self.callback)(self.userdata, true);
        std::mem::forget(self)
    }
    pub fn failed(self) {
        (self.callback)(self.userdata, false);
        std::mem::forget(self)
    }
}

impl Drop for CompletedCallback {
    fn drop(&mut self) {
        panic!("CompletedCallback must have explicit succeeded or failed call")
    }
}
```

From the code we can see the types has the requirement that `succeeded` or `failed` must be called, and that it can only be used once.

Nothing about the type is actually Swift specific. This type can be used in any language capable of FFI via C ABI.

Next is a quick example of an asynchronous function callable via C ABI.

```rust
#[no_mangle]
pub extern "C" fn async_operation(callback: CompletedCallback) {
    thread::spawn(move || {
        thread::sleep(Duration::from_secs(3));
        callback.succeeded()
    });
}
```

## Swift Implementation
As we move to the Swift calling side we'll need to create a bridging header so that Swift recognizes our types and function.

```c
#ifndef BridgingHeader_h
#define BridgingHeader_h

#import <Foundation/Foundation.h>

typedef struct CompletedCallback {
    void * _Nonnull userdata;
    void (* _Nonnull callback)(void * _Nonnull, bool);
} CompletedCallback;

void async_operation(CompletedCallback callback);

#endif
```

Then we need to wrap the imported function with function that presents an idiomatic interface. This is we're we'll map to our Rust types and handle manual reference counting.
```swift
private class WrapClosure<T> {
    fileprivate let closure: T
    init(closure: T) {
        self.closure = closure
    }
}
public func FriendlyAsyncOperation(closure: @escaping (Bool) -> Void) {
    // step 1
    let wrappedClosure = WrapClosure(closure: closure)
    let userdata = Unmanaged.passRetained(wrappedClosure).toOpaque()

    // step 2
    let callback: @convention(c) (UnsafeMutableRawPointer, Bool) -> Void = { (_ userdata: UnsafeMutableRawPointer, _ success: Bool) in
        let wrappedClosure: WrapClosure<(Bool) -> Void> = Unmanaged.fromOpaque(userdata).takeRetainedValue()
        wrappedClosure.closure(success)
    }

    // step 3
    let completion = CompletedCallback(userdata: userdata, callback: callback)

    //step 4
    async_operation(completion)
}
```

#### Step 1
We need to take our Swift closure and turn it into a `void *` so it can be the `userdata` member. `Unmanaged.passRetained` will manually increment the reference count and give us an unmanaged object which can be cast using `toOpaque`. Unfortunately in Swift closures are not something we can manually retain, so we need to make it a property of the `WrapClosure` type.

#### Step 2
We create a C compatible function pointer to an inner helper closure. This closure has a signature that matches our C api: `(void * _Nonnull userdata, bool success)`. In this helper closure we reverse step 1 and manually decrement the reference count on the closure and turn it back to a Swift type. Because we are back to letting Swift manage our reference count, when the scope ends the wrapped closure will be freed.

#### Step 3
We can initialize all the members of the C callback structure without the calling code having to worry about `@convention(c)` closures and `UnsafeMutableRawPointer`

#### Step 4
Invoke the Rust function

## Example Swift Caller
We'll demonstrate the recipe with a Swift CLI application:
```swift
class TestLifetime {
    let sema: DispatchSemaphore
    init(_ sema: DispatchSemaphore) {
        self.sema = sema
        print("start of test lifetime")
    }

    deinit {
        print("end of test lifetime")
    }

    func completed(_ success: Bool) {
        print("the async operation has completed with result \(success)")
        sema.signal()
    }
}

func startOperation(_ sema: DispatchSemaphore) {
    let test = TestLifetime(sema) 
    print("starting async operation")
    FriendlyAsyncOperation() { [test] success in
        test.completed(success)
    }
}

let semaphore = DispatchSemaphore(value: 0)
startOperation(semaphore)
semaphore.wait()
```

Invoking `FriendlyAsyncOperation()` looks just like any other asynchronous Swift function.

If we run the above code we get the following output

```
start of test lifetime
starting async operation
the async operation has completed with result true
end of test lifetime
```

The instance of `TestLifetime` has been captured and it's lifetime is extended beyond the scope of the `startOperation` function and lasts until the asynchronous operation in Rust has completed.

# Code
All the code can be found on [Github](https://github.com/nickwilcox/recipe-swift-rust-callbacks)