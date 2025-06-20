# ===----------------------------------------------------------------------=== #
# Copyright (c) 2025, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===----------------------------------------------------------------------=== #
"""Establishes the contract between `Writer` and `Writable` types."""

from bit import byte_swap
from collections import InlineArray
from sys.info import is_amd_gpu, is_gpu, is_nvidia_gpu

from memory import Span, UnsafePointer, memcpy, bitcast

# ===-----------------------------------------------------------------------===#


trait Writer:
    """Describes a type that can be written to by any type that implements the
    `write_to` function.

    This enables you to write one implementation that can be written to a
    variety of types such as file descriptors, strings, network locations etc.
    The types are written as a `Span[Byte]`, so the `Writer` can avoid
    allocations depending on the requirements. There is also a general `write`
    that takes multiple args that implement `write_to`.

    Example:

    ```mojo
    from memory import Span

    @fieldwise_init
    struct NewString(Writer, Writable, Copyable, Movable):
        var s: String

        # Writer requirement to write a Span of Bytes
        fn write_bytes(mut self, bytes: Span[Byte, _]):
            self.s._iadd(bytes)

        # Writer requirement to take multiple args
        fn write[*Ts: Writable](mut self, *args: *Ts):
            @parameter
            for i in range(args.__len__()):
                args[i].write_to(self)

        # Also make it Writable to allow `print` to write the inner String
        fn write_to[W: Writer](self, mut writer: W):
            writer.write(self.s)


    @fieldwise_init
    struct Point(Writable, Copyable, Movable):
        var x: Int
        var y: Int

        # Pass multiple args to the Writer. The Int and StaticString types
        # call `writer.write_bytes` in their own `write_to` implementations.
        fn write_to[W: Writer](self, mut writer: W):
            writer.write("Point(", self.x, ", ", self.y, ")")

        # Enable conversion to a String using `String(point)`
        fn __str__(self) -> String:
            return String.write(self)


    fn main():
        var point = Point(1, 2)
        var new_string = NewString(String(point))
        new_string.write("\\n", Point(3, 4))
        print(new_string)
    ```

    Output:

    ```plaintext
    Point(1, 2)
    Point(3, 4)
    ```
    """

    @always_inline
    fn write_bytes(mut self, bytes: Span[Byte, _]):
        """
        Write a `Span[Byte]` to this `Writer`.

        Args:
            bytes: The string slice to write to this Writer. Must NOT be
              null-terminated.
        """
        ...

    fn write[*Ts: Writable](mut self, *args: *Ts):
        """Write a sequence of Writable arguments to the provided Writer.

        Parameters:
            Ts: Types of the provided argument sequence.

        Args:
            args: Sequence of arguments to write to this Writer.
        """
        ...
        # TODO: When have default implementations on traits, we can use this:
        # @parameter
        # for i in range(args.__len__()):
        #     args[i].write_to(self)
        #
        # To only have to implement `write_bytes` to make a type a valid Writer


# ===-----------------------------------------------------------------------===#
# Writable
# ===-----------------------------------------------------------------------===#


trait Writable:
    """The `Writable` trait describes how a type is written into a `Writer`.

    You must implement `write_to` which takes `self` and a type conforming to
    `Writer`:

    ```mojo
    struct Point(Writable):
        var x: Float64
        var y: Float64

        fn write_to[W: Writer](self, mut writer: W):
            var string = "Point"
            # Write a single `Span[Byte]`:
            writer.write_bytes(string.as_bytes())
            # Pass multiple args that can be converted to a `Span[Byte]`:
            writer.write("(", self.x, ", ", self.y, ")")
    ```
    """

    fn write_to[W: Writer](self, mut writer: W):
        """
        Formats the string representation of this type to the provided Writer.

        Parameters:
            W: A type conforming to the Writable trait.

        Args:
            writer: The type conforming to `Writable`.
        """
        ...


# ===-----------------------------------------------------------------------===#
# Utils
# ===-----------------------------------------------------------------------===#


fn write_args[
    W: Writer, *Ts: Writable
](
    mut writer: W,
    args: VariadicPack[_, _, Writable, *Ts],
    *,
    sep: StaticString = StaticString(),
    end: StaticString = StaticString(),
):
    """
    Add separators and end characters when writing variadics into a `Writer`.

    Parameters:
        W: The type of the `Writer` to write to.
        Ts: The types of each arg to write. Each type must satisfy `Writable`.

    Args:
        writer: The `Writer` to write to.
        args: A VariadicPack of Writable arguments.
        sep: The separator used between elements.
        end: The String to write after printing the elements.

    Example

    ```mojo
    import sys
    from utils import write_args

    fn variadic_pack_function[*Ts: Writable](
        *args: *Ts, sep: StaticString, end: StaticString
    ):
        var stdout = sys.stdout
        write_args(stdout, args, sep=sep, end=end)

    variadic_pack_function(3, "total", "args", sep=",", end="[end]")
    ```

    ```
    3, total, args[end]
    ```
    """

    @parameter
    for i in range(args.__len__()):
        args[i].write_to(writer)
        if i < args.__len__() - 1:
            sep.write_to(writer)

    if end:
        end.write_to(writer)


struct _WriteBufferHeap(Writer):
    var data: UnsafePointer[UInt8]
    var pos: Int

    fn __init__(out self, size: Int):
        self.data = UnsafePointer[
            UInt8, address_space = AddressSpace.GENERIC
        ].alloc(size)
        self.pos = 0

    fn write_list[
        T: Copyable & Movable & Writable, //
    ](mut self, values: List[T, *_], *, sep: StaticString = StaticString()):
        var length = len(values)
        if length == 0:
            return
        self.write(values[0])
        if length > 1:
            for i in range(1, length):
                self.write(sep, values[i])

    @always_inline
    fn write_bytes(mut self, bytes: Span[UInt8, _]):
        len_bytes = len(bytes)
        var ptr = bytes.unsafe_ptr()

        # TODO: fix memcpy alignment on nvidia GPU
        @parameter
        if is_nvidia_gpu():
            for i in range(len_bytes):
                self.data[i + self.pos] = ptr[i]
        else:
            memcpy(self.data + self.pos, ptr, len_bytes)

        self.pos += len_bytes

    fn write[*Ts: Writable](mut self, *args: *Ts):
        @parameter
        for i in range(args.__len__()):
            args[i].write_to(self)


struct _TotalWritableBytes(Writer):
    var size: Int

    fn __init__(out self):
        self.size = 0

    fn __init__[
        T: Copyable & Movable & Writable, //
    ](out self, values: List[T, *_], sep: String = String()):
        self.size = 0
        var length = len(values)
        if length == 0:
            return
        self.write(values[0])
        if length > 1:
            for i in range(1, length):
                self.write(sep, values[i])

    fn write_bytes(mut self, bytes: Span[UInt8, _]):
        self.size += len(bytes)

    fn write[*Ts: Writable](mut self, *args: *Ts):
        @parameter
        for i in range(args.__len__()):
            args[i].write_to(self)


struct _WriteBufferStack[
    origin: MutableOrigin, W: Writer, //, capacity: Int = 4096
](Writer):
    var data: InlineArray[UInt8, capacity]
    var pos: Int
    var writer: Pointer[W, origin]

    @implicit
    fn __init__(out self, ref [origin]writer: W):
        self.data = InlineArray[UInt8, capacity](uninitialized=True)
        self.pos = 0
        self.writer = Pointer(to=writer)

    fn write_list[
        T: Copyable & Movable & Writable, //
    ](mut self, values: List[T, *_], *, sep: String = String()):
        var length = len(values)
        if length == 0:
            return
        self.write(values[0])
        if length > 1:
            for i in range(1, length):
                self.write(sep, values[i])

    fn flush(mut self):
        self.writer[].write_bytes(
            Span[Byte, ImmutableAnyOrigin](
                ptr=self.data.unsafe_ptr(), length=self.pos
            )
        )
        self.pos = 0

    fn write_bytes(mut self, bytes: Span[Byte, _]):
        len_bytes = len(bytes)
        # If span is too large to fit in buffer, write directly and return
        if len_bytes > capacity:
            self.flush()
            self.writer[].write_bytes(bytes)
            return
        # If buffer would overflow, flush writer and reset pos to 0.
        elif self.pos + len_bytes > capacity:
            self.flush()
        # Continue writing to buffer
        memcpy(self.data.unsafe_ptr() + self.pos, bytes.unsafe_ptr(), len_bytes)
        self.pos += len_bytes

    fn write[*Ts: Writable](mut self, *args: *Ts):
        @parameter
        for i in range(args.__len__()):
            args[i].write_to(self)


fn write_buffered[
    W: Writer, //,
    *Ts: Writable,
    buffer_size: Int = 4096,
    use_heap: Bool = False,
](
    mut writer: W,
    args: VariadicPack[_, _, Writable, *Ts],
    *,
    sep: StaticString = StaticString(),
    end: StaticString = StaticString(),
):
    """
    Use a buffer on the stack to minimize expensive calls to the writer. When
    the buffer would overflow it writes to the `writer` passed in. You can also
    add separators between the args, and end characters. The default stack space
    used for the buffer is 4096 bytes which matches the default arm64 and x86-64
    page size, you can modify this e.g. when writing a large amount of data to a
    file.

    Parameters:
        W: The type of the `Writer` to write to.
        Ts: The types of each arg to write. Each type must satisfy `Writable`.
        buffer_size: How many bytes to write to a buffer before writing out to
            the `writer` (default `4096`).
        use_heap: Buffer to the heap, first calculating the total byte size
            of all the args and then allocating only once. `buffer_size` is not
            used in this case as it's dynamically calculated. (default `False`).

    Args:
        writer: The `Writer` to write to.
        args: A VariadicPack of Writable arguments.
        sep: The separator used between elements.
        end: The String to write after printing the elements.

    Example

    ```mojo
    import sys
    from utils import write_buffered

    fn print_err_buffered[*Ts: Writable](
        *args: *Ts, sep: StaticString, end: StaticString
    ):
        var stderr = sys.stderr
        write_buffered(stderr, args, sep=sep, end=end)

        # Buffer before allocating a string
        var string = String()
        write_buffered(string, args, sep=sep, end=end)


    print_err_buffered(3, "total", "args", sep=",", end="[end]")
    ```

    ```
    3, total, args[end]
    ```
    .
    """

    @parameter
    if use_heap:
        # Count the total length of bytes to allocate only once
        var arg_bytes = _TotalWritableBytes()
        write_args(arg_bytes, args, sep=sep, end=end)

        var buffer = _WriteBufferHeap(arg_bytes.size + 1)
        write_args(buffer, args, sep=sep, end=end)
        buffer.data[buffer.pos] = 0
        writer.write_bytes(
            Span[Byte, ImmutableAnyOrigin](ptr=buffer.data, length=buffer.pos)
        )
        buffer.data.free()
    else:
        var buffer = _WriteBufferStack[buffer_size](writer)
        write_args(buffer, args, sep=sep, end=end)
        buffer.flush()


fn write_buffered[
    W: Writer,
    T: Copyable & Movable & Writable, //,
    buffer_size: Int = 4096,
](mut writer: W, values: List[T, *_], *, sep: StaticString = StaticString()):
    """
    Use a buffer on the stack to minimize expensive calls to the writer. You
    can also add separators between the values. The default stack space used for
    the buffer is 4096 bytes which matches the default arm64 and x86-64 page
    size, you can modify this e.g. when writing a large amount of data to a
    file.

    Parameters:
        W: The type of the `Writer` to write to.
        T: The element type of the `List`. Must implement the `Writable`,
            `Copyable` and `Movable` traits.
        buffer_size: How many bytes to write to a buffer before writing out to
            the `writer` (default `4096`).

    Args:
        writer: The `Writer` to write to.
        values: A `List` of Writable arguments.
        sep: The separator used between elements.

    Example

    ```mojo
    import sys
    from utils import write_buffered

    var string = String()
    var values = [String("3"), "total", "args"]
    write_buffered(string, values, sep=",")
    ```

    ```
    3, total, args
    ```
    .
    """
    var buffer = _WriteBufferStack(writer)
    buffer.write_list(values, sep=sep)
    buffer.flush()


@fieldwise_init
@register_passable
struct WritableVariadicPack[
    mut: Bool, //,
    is_owned: Bool,
    origin: Origin[mut],
    pack_origin: Origin[mut],
    *Ts: Writable,
](Writable):
    """Wraps a `VariadicPack`, enabling it to be passed to a writer along with
    extra arguments.

    Parameters:
        mut: Whether the origin is mutable.
        is_owned: Whether the `VariadicPack` owns its elements.
        origin: The origin of the reference to the `VariadicPack`.
        pack_origin: The origin of the `VariadicPack`.
        Ts: The types of the variadic arguments conforming to `Writable`.

    Example:

    ```mojo
    from utils.write import WritableVariadicPack

    fn foo[*Ts: Writable](*messages: *Ts):
        print("message:", WritableVariadicPack(messages), "[end]")

    x = 42
    foo("'x = ", x, "'")
    ```

    Output:

    ```text
    message: 'x = 42' [end]
    ```
    """

    var value: Pointer[
        VariadicPack[is_owned, pack_origin, Writable, *Ts], origin
    ]
    """Reference to a `VariadicPack` that conforms to `Writable`."""

    fn __init__(
        out self,
        ref [origin]value: VariadicPack[is_owned, pack_origin, Writable, *Ts],
    ):
        """Initialize using a reference to the `VariadicPack`.

        Args:
            value: The `VariadicPack` to take a reference to.
        """
        self.value = Pointer(to=value)

    fn write_to[W: Writer](self, mut writer: W):
        """
        Formats the string representation of all the arguments in the
        `VariadicPack` to the provided `Writer`.

        Parameters:
            W: A type conforming to the Writable trait.

        Args:
            writer: The type conforming to `Writable`.
        """
        write_args(writer, self.value[])


# ===-----------------------------------------------------------------------===#
# Utils
# ===-----------------------------------------------------------------------===#


# fmt: off
alias _hex_table = SIMD[DType.uint8, 16](
    ord("0"), ord("1"), ord("2"), ord("3"), ord("4"),
    ord("5"), ord("6"), ord("7"), ord("8"), ord("9"),
    ord("a"), ord("b"), ord("c"), ord("d"), ord("e"), ord("f"),
)
# fmt: on


@always_inline
fn _hex_digits_to_hex_chars(ptr: UnsafePointer[Byte], decimal: Scalar):
    """Write a fixed width hexadecimal value into an uninitialized pointer
    location, assumed to be large enough for the value to be written.

    Examples:

    ```mojo
    %# from memory import memset_zero
    %# from testing import assert_equal
    %# from utils import StringSlice
    %# from utils.write import _hex_digits_to_hex_chars
    items = List[Byte](0, 0, 0, 0, 0, 0, 0, 0, 0)
    alias S = StringSlice[__origin_of(items)]
    ptr = items.unsafe_ptr()
    _hex_digits_to_hex_chars(ptr, UInt32(ord("🔥")))
    assert_equal("0001f525", S(ptr=ptr, length=8))
    memset_zero(ptr, len(items))
    _hex_digits_to_hex_chars(ptr, UInt16(ord("你")))
    assert_equal("4f60", S(ptr=ptr, length=4))
    memset_zero(ptr, len(items))
    _hex_digits_to_hex_chars(ptr, UInt8(ord("Ö")))
    assert_equal("d6", S(ptr=ptr, length=2))
    ```
    .
    """

    alias size = decimal.dtype.sizeof()
    var data: SIMD[DType.uint8, size]

    @parameter
    if size == 1:
        data = bitcast[DType.uint8, size](decimal)
    else:
        data = bitcast[DType.uint8, size](byte_swap(decimal))
    var nibbles = (data >> 4).interleave(data & 0xF)
    ptr.store(_hex_table._dynamic_shuffle(nibbles))


@always_inline
fn _write_hex[amnt_hex_bytes: Int](p: UnsafePointer[Byte], decimal: Int):
    """Write a python compliant hexadecimal value into an uninitialized pointer
    location, assumed to be large enough for the value to be written.

    Examples:

    ```mojo
    %# from memory import memset_zero
    %# from testing import assert_equal
    %# from utils import StringSlice
    %# from utils.write import _write_hex
    items = List[Byte](0, 0, 0, 0, 0, 0, 0, 0, 0)
    alias S = StringSlice[__origin_of(items)]
    ptr = items.unsafe_ptr()
    _write_hex[8](ptr, ord("🔥"))
    assert_equal(r"\\U0001f525", S(ptr=ptr, length=10))
    memset_zero(ptr, len(items))
    _write_hex[4](ptr, ord("你"))
    assert_equal(r"\\u4f60", S(ptr=ptr, length=6))
    memset_zero(ptr, len(items))
    _write_hex[2](ptr, ord("Ö"))
    assert_equal(r"\\xd6", S(ptr=ptr, length=4))
    ```
    """

    constrained[amnt_hex_bytes in (2, 4, 8), "only 2 or 4 or 8 sequences"]()

    alias `\\` = Byte(ord("\\"))
    alias `x` = Byte(ord("x"))
    alias `u` = Byte(ord("u"))
    alias `U` = Byte(ord("U"))

    p.init_pointee_move(`\\`)

    @parameter
    if amnt_hex_bytes == 2:
        (p + 1).init_pointee_move(`x`)
        _hex_digits_to_hex_chars(p + 2, UInt8(decimal))
    elif amnt_hex_bytes == 4:
        (p + 1).init_pointee_move(`u`)
        _hex_digits_to_hex_chars(p + 2, UInt16(decimal))
    else:
        (p + 1).init_pointee_move(`U`)
        _hex_digits_to_hex_chars(p + 2, UInt32(decimal))
