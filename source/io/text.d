/**
 * Copyright: Copyright Jason White, 2015
 * License:   $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors:   Jason White
 *
 * TODO: Find a more elegant way of reading and writing text.
 *
 * TODO: Be able to set the default output.
 */
module io.text;

import io.stream;

import io.file.stdio : stdout;
import std.algorithm : forward;

/**
 * Serializes the given arguments to a text representation followed by a new
 * line.
 */
size_t print(Stream, T...)(Stream stream, auto ref T args)
    if (isSink!Stream)
{
    import std.conv : to;

    size_t length;

    foreach (arg; args)
        length += stream.write(arg.to!string);

    return length;
}

/// Ditto
size_t print(T...)(auto ref T args)
    if (T.length > 0 && !isSink!(T[0]))
{
    return stdout.print(forward!args);
}

unittest
{
    import io.file.pipe;
    import std.typecons : tuple;
    import std.typetuple : TypeTuple;

    // First tuple value is expected output. Remaining are the types to be
    // printed.
    alias tests = TypeTuple!(
        tuple(""),
        tuple("Test", "Test"),
        tuple("[4, 8, 15, 16, 23, 42]", [4, 8, 15, 16, 23, 42]),
        tuple("The answer is 42", "The answer is ", 42),
        tuple("01234567890", 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0),
        );

    foreach (t; tests)
    {
        auto f = pipe();
        immutable output = t[0];
        char[output.length] buf;
        assert(f.writeEnd.print(t[1 .. $]) == output.length);
        assert(f.readEnd.read(buf) == buf.length);
        assert(buf == output);
    }
}

/**
 * Serializes the given arguments to a text representation followed by a new
 * line.
 */
size_t println(T...)(auto ref T args)
{
    return print(forward!args, '\n');
}

unittest
{
    import io.file.pipe;
    import std.typecons : tuple;
    import std.typetuple : TypeTuple;

    // First tuple value is expected output. Remaining are the types to be
    // printed.
    alias tests = TypeTuple!(
        tuple("\n"),
        tuple("Test\n", "Test"),
        tuple("[4, 8, 15, 16, 23, 42]\n", [4, 8, 15, 16, 23, 42]),
        tuple("The answer is 42\n", "The answer is ", 42),
        tuple("01234567890\n", 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0),
        );

    foreach (t; tests)
    {
        auto f = pipe();
        immutable output = t[0];
        char[output.length] buf;
        assert(f.writeEnd.println(t[1 .. $]) == output.length);
        assert(f.readEnd.read(buf) == buf.length);
        assert(buf == output);
    }
}

/**
 * Serializes the given arguments according to the given format specifier
 * string.
 */
void printf(Stream, T...)(Stream stream, string format, auto ref T args)
    if (isSink!Stream)
{
    import std.format : formattedWrite;
    formattedWrite(stream, forward!(format, args));
}

/// Ditto
void printf(T...)(string format, auto ref T args)
{
    stdout.printf(forward!(format, args));
}

unittest
{
    import io.file.pipe;
    import std.typecons : tuple;
    import std.typetuple : TypeTuple;

    // First tuple value is expected output. Remaining are the types to be
    // printed.
    alias tests = TypeTuple!(
        tuple("", ""),
        tuple("Test", "Test"),
        tuple("The answer is 42.", "The answer is %d.", 42),
        tuple("Hello, my name is Inigo Montoya", "Hello, my name is %s %s...",
            "Inigo", "Montoya")
        );

    foreach (t; tests)
    {
        auto f = pipe();
        immutable output = t[0];
        char[output.length] buf;
        f.writeEnd.printf(t[1 .. $]);
        assert(f.readEnd.read(buf) == buf.length);
        assert(buf == output);
    }
}

/**
 * Like $(D writef), but also writes a new line.
 */
void printfln(Stream, T...)(Stream stream, string format, auto ref T args)
    if (isSink!Stream)
{
    stream.printf(forward!(format, args));
    stream.print('\n');
}

/// Ditto
void printfln(T...)(string format, auto ref T args)
{
    stdout.printfln(forward!(format, args));
}

/**
 * Convenience function for returning a delimiter range that iterates over
 * lines.
 */
@property auto byLine(T = char, Stream)(Stream stream)
    if (isSource!Stream)
{
    import io.range : splitter;
    return splitter!T(stream, '\n');
}
