/**
 * Copyright: Copyright Jason White, 2014
 * License:   $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors:   Jason White
 */
module io.file.stream;

import io.stream;
public import io.file.flags;

version (unittest)
{
    import file = std.file; // For easy file creation/deletion.
    import io.file.temp;
}

version (Posix)
{
    import core.sys.posix.fcntl;
    import core.sys.posix.unistd;
    import std.exception : ErrnoException;

    version (linux)
    {
        extern (C): @system: nothrow:
        ssize_t sendfile(int out_fd, int in_fd, off_t *offset, size_t count);
    }

    enum
    {
        SEEK_SET,
        SEEK_CUR,
        SEEK_END
    }

    // FIXME: This should be moved into a separate module.
    alias SysException = ErrnoException;
}
else version (Windows)
{
    import core.sys.windows.windows;

    // These are not declared in core.sys.windows.windows
    extern (Windows) nothrow export
    {
        BOOL SetFilePointerEx(
            HANDLE hFile,
            long liDistanceToMove,
            long* lpNewFilePointer,
            DWORD dwMoveMethod
        );

        BOOL GetFileSizeEx(
            HANDLE hFile,
            long* lpFileSize
        );
    }

    // FIXME: This should be moved into a separate module.
    class SysException : Exception
    {
        uint errCode;

        this(string msg, string file = null, size_t line = 0)
        {
            import std.windows.syserror : sysErrorString;
            errCode = GetLastError();
            super(msg ~ " (" ~ sysErrorString(errCode) ~ ")", file, line);
        }
    }
}
else
{
    static assert(false, "Unsupported platform.");
}

// FIXME: This should be moved into a separate module.
T sysEnforce(T, string file = __FILE__, size_t line = __LINE__)
    (T value, lazy string msg = null)
{
    if (!value) throw new SysException(msg, file, line);
    return value;
}

/**
 * A light-weight, cross-platform wrapper around low-level file operations.
 */
final class File
{
    // Platform-specific file handle
    version (Posix)
    {
        alias Handle = int;
        enum Handle InvalidHandle = -1;
    }
    else version (Windows)
    {
        alias Handle = HANDLE;
        enum Handle InvalidHandle = INVALID_HANDLE_VALUE;
    }

    private Handle _h = InvalidHandle;

    /**
     * Allows creating a file without using new.
     */
    static typeof(this) opCall(T...)(T args)
    {
        return new typeof(this)(args);
    }

    /**
     * Opens or creates a file by name. By default, an existing file is opened
     * in read-only mode.
     *
     * Params:
     *     name = The name of the file.
     *     flags = How to open the file.
     *
     * Example:
     * ---
     * // Create a brand-new file and write to it. Throws an exception if the
     * // file already exists. The file is automatically closed when it falls
     * // out of scope.
     * auto f = File("filename", FileFlags.writeNew);
     * f.write("Hello world!");
     * ---
     */
    this(string name, FileFlags flags = FileFlags.readExisting)
    {
        open(name, flags);
    }

    /// Ditto
    void open(string name, FileFlags flags = FileFlags.readExisting)
    {
        version (Posix)
        {
            import std.string : toStringz;

            _h = .open(toStringz(name), flags.flags, 0b110_000_000);
        }
        else version (Windows)
        {
            import std.utf : toUTF16z;

            _h = .CreateFileW(
                name.toUTF16z(),       // File name
                flags.access,          // Desired access
                flags.share,           // Share mode
                null,                  // Security attributes
                flags.mode,            // Creation disposition
                FILE_ATTRIBUTE_NORMAL, // Flags and attributes
                null,                  // Template file handle
                );
        }

        sysEnforce(_h != InvalidHandle, "Failed to open file '"~ name ~"'");
    }

    unittest
    {
        import std.exception : ce = collectException;

        // Ensure files are opened the way they are supposed to be opened.

        immutable data = "12345678";
        ubyte[data.length] buf;

        auto tf = testFile();

        // Make sure the file does *not* exist
        try .file.remove(tf.name); catch (Exception e) {}

        assert( File(tf.name, FileFlags.readExisting).ce);
        assert( File(tf.name, FileFlags.writeExisting).ce);
        assert(!File(tf.name, FileFlags.writeNew).ce);
        assert(!File(tf.name, FileFlags.writeAlways).ce);

        // Make sure the file *does* exist.
        .file.write(tf.name, data);

        assert(!File(tf.name, FileFlags.readExisting).ce);
        assert(!File(tf.name, FileFlags.writeExisting).ce);
        assert( File(tf.name, FileFlags.writeNew).ce);
        assert(!File(tf.name, FileFlags.writeAlways).ce);
    }

    /**
     * Takes control of a file handle.
     *
     * It is assumed that we have exclusive control over the file handle and will
     * be closed upon destruction as usual.
     *
     * This function is useful in a couple of situations:
     * $(UL
     *   $(LI
     *     The file must be opened with special flags that cannot be obtained
     *     via $(D FileFlags)
     *   )
     *   $(LI
     *     A special file handle must be opened (e.g., $(D stdout), a pipe).
     *   )
     * )
     *
     * Params:
     *   h = The handle to assume control over. For Posix, this is a file
     *       descriptor ($(D int)). For Windows, this is an object handle ($(D
     *       HANDLE)).
     */
    this(Handle h)
    {
        open(h);
    }

    /// Ditto
    void open(Handle h)
    {
        _h = h;
    }

    /**
     * Duplicate the internal file handle.
     */
    typeof(this) dup()
    in { assert(isOpen); }
    body
    {
        version (Posix)
        {
            immutable h = .dup(_h);
            sysEnforce(h != InvalidHandle, "Failed to duplicate handle");
            return new File(h);
        }
        else version (Windows)
        {
            auto proc = GetCurrentProcess();
            auto ret = DuplicateHandle(
                proc, // Process with the file handle
                _h,   // Handle to duplicate
                proc, // Process for the duplicated handle
                &_h,  // The duplicated handle
                0,    // Access flags, ignored
                true, // Allow this handle to be inherited
                DUPLICATE_SAME_ACCESS
            );
            sysEnforce(ret, "Failed to duplicate handle");
            return File(ret);
        }
    }

    unittest
    {
        auto tf = testFile();

        auto a = File(tf.name, FileFlags.writeEmpty);

        auto b = a.dup; // Copy
        b.write("abcd");

        assert(a.position == 4);
    }

    unittest
    {
        // File is copied when passed to the function.
        static void foo(File f)
        {
            f.write("abcd");
        }

        auto tf = testFile();
        auto f = File(tf.name, FileFlags.writeEmpty);

        assert(f.position == 0);

        foo(f);

        assert(f.position == 4);
    }

    /**
     * Closes the file stream.
     */
    void close()
    {
        // Not opened.
        if (!isOpen) return;

        version (Posix)
        {
            sysEnforce(.close(_h) != -1, "Failed to close file");
        }
        else version (Windows)
        {
            sysEnforce(CloseHandle(_h), "Failed to close file");
        }

        _h = InvalidHandle;
    }

    /// Ditto
    ~this()
    {
        close();
    }

    /**
     * Returns true if the file is open.
     */
    @property bool isOpen() const pure nothrow
    {
        return _h != InvalidHandle;
    }

    /// Ditto
    //alias opCast(T : bool) = isOpen;

    unittest
    {
        auto tf = testFile();

        //File f = File();
        //assert(!f.isOpen);
        //assert(!f);

        auto f = File(tf.name, FileFlags.writeAlways);
        assert(f.isOpen);
        f.close();
        assert(!f.isOpen);
    }

    /**
     * Returns the internal file handle. On POSIX, this is a file descriptor. On
     * Windows, this is an object handle.
     */
    @property Handle handle() pure nothrow
    {
        return _h;
    }

    /**
     * Reads data from the file.
     *
     * Params:
     *   buf = The buffer to read the data into. The length of the buffer
     *         specifies how much data should be read.
     *
     * Returns: The number of bytes that were read. 0 indicates that the end of
     * the file has been reached.
     */
    size_t read(void[] buf)
    in { assert(isOpen); }
    body
    {
        version (Posix)
        {
            immutable n = .read(_h, buf.ptr, buf.length);
            sysEnforce(n >= 0);
            return n;
        }
        else version (Windows)
        {
            DWORD n = void;
            sysEnforce(ReadFile(_h, buf.ptr, buf.length, &n, null));
            return n;
        }
    }

    unittest
    {
        auto tf = testFile();

        immutable data = "\r\n\n\r\n";
        file.write(tf.name, data);

        char[data.length] buf;

        auto f = File(tf.name, FileFlags.readExisting);
        assert(buf[0 .. f.read(buf)] == data);
    }

    /**
     * Writes data to the file.
     *
     * Params:
     *   data = The data to write to the file. The length of the slice indicates
     *          how much data should be written.
     *
     * Returns: The number of bytes that were written.
     */
    size_t write(in void[] data)
    in { assert(isOpen); }
    body
    {
        version (Posix)
        {
            immutable n = .write(_h, data.ptr, data.length);
            sysEnforce(n != -1);
            return cast(size_t)n;
        }
        else version (Windows)
        {
            DWORD written = void;
            sysEnforce(
                WriteFile(_h, data.ptr, data.length, &written, null)
                );
            return written;
        }
    }

    unittest
    {
        auto tf = testFile();

        immutable data = "\r\n\n\r\n";
        char[data.length] buf;

        assert(File(tf.name, FileFlags.writeEmpty).write(data) == data.length);
        assert(File(tf.name, FileFlags.readExisting).read(buf));
        assert(buf == data);
    }

    /// An absolute position in the file.
    alias Position = ulong;

    /// An offset from an absolute position
    alias Offset = long;

    /// Special positions.
    static immutable Position
        start = 0,
        end   = Position.max;

    /**
     * Seeks relative to a position.
     *
     * Params:
     *   offset = Offset relative to a reference point.
     *   from   = Optional reference point.
     */
    ulong seekTo(Offset offset, From from = From.start)
    in { assert(isOpen); }
    body
    {
        version (Posix)
        {
            int whence = void;

            final switch (from)
            {
                case From.start: whence = SEEK_SET; break;
                case From.here:  whence = SEEK_CUR; break;
                case From.end:   whence = SEEK_END; break;
            }

            immutable pos = .lseek(_h, offset, whence);
            sysEnforce(pos != -1, "Failed to seek to position");
            return pos;
        }
        else version (Windows)
        {
            DWORD whence = void;

            final switch (from)
            {
                case From.start: whence = FILE_BEGIN;   break;
                case From.here:  whence = FILE_CURRENT; break;
                case From.end:   whence = FILE_END;     break;
            }

            Offset pos = void;
            sysEnforce(SetFilePointerEx(_h, offset, &pos, whence),
                "Failed to seek to position");
            return pos;
        }
    }

    unittest
    {
        auto tf = testFile();

        auto f = File(tf.name, FileFlags.readWriteAlways);

        immutable data = "abcdefghijklmnopqrstuvwxyz";
        assert(f.write(data) == data.length);

        assert(f.seekTo(5) == 5);
        assert(f.skip(5) == 10);
        assert(f.seekTo(-5, From.end) == data.length - 5);

        // Test large offset
        assert(f.seekTo(Offset.max) == Offset.max);
    }

    /**
     * Gets the size of the file.
     */
    @property Offset length()
    in { assert(isOpen); }
    body
    {
        version(Posix)
        {
            // Note that this uses stat to get the length of the file instead of
            // the seek method. This method is safer because it is atomic.
            stat_t stat;
            sysEnforce(.fstat(_h, &stat) != -1);
            return stat.st_size;
        }
        else version (Windows)
        {
            long size = void;
            sysEnforce(GetFileSizeEx(_h, &size));
            return size;
        }
    }

    unittest
    {
        auto tf = testFile();
        auto f = File(tf.name, FileFlags.writeEmpty);

        assert(f.length == 0);

        immutable data = "0123456789";
        assert(f.write(data) == data.length);
        auto m = f.seekTo(3);

        assert(f.length == data.length);

        assert(f.position == m);
    }

    /**
     * Sets the length of the file. This can be used to truncate or extend the
     * length of the file. If the file is extended, the new segment is not
     * guaranteed to be initialized to zeros.
     */
    @property void length(Offset len)
    in { assert(isOpen); }
    body
    {
        version (Posix)
        {
            sysEnforce(
                ftruncate(_h, len) == 0,
                "Failed to set the length of the file"
                );
        }
        else version (Windows)
        {
            // FIXME: Is this thread-safe?
            auto pos = seekTo(len);   // Seek to the correct position
            scope (exit) seekTo(pos); // Seek back

            sysEnforce(
                SetEndOfFile(_h),
                "Failed to set the length of the file"
                );
        }
    }

    unittest
    {
        auto tf = testFile();
        auto f = File(tf.name, FileFlags.writeEmpty);
        assert(f.length == 0);
        assert(f.position == 0);

        // Extend
        f.length = 100;
        assert(f.length == 100);
        assert(f.position == 0);

        // Truncate
        f.length = 0;
        assert(f.length == 0);
        assert(f.position == 0);
    }

    /**
     * Checks if the file is a terminal.
     */
    @property bool isTerminal()
    in { assert(isOpen); }
    body
    {
        version (Posix)
        {
            return isatty(_h) == 1;
        }
        else version (Windows)
        {
            // TODO: Use GetConsoleMode
            static assert(false, "Implement me!");
        }
    }

    enum LockType
    {
        /**
         * Shared access to the locked file. Other processes can also access the
         * file.
         */
        read,

        /**
         * Exclusive access to the locked file. No other processes may access
         * the file.
         */
        readWrite,
    }

    version (Posix)
    {
        private int lockImpl(int operation, short type,
            Offset start, Offset length)
        {
            flock fl = {
                l_type:   type,
                l_whence: SEEK_SET,
                l_start:  start,
                l_len:    (length == Offset.max) ? 0 : length,
                l_pid:    -1,
            };

            return .fcntl(_h, operation, &fl);
        }
    }
    else version (Windows)
    {
        private BOOL lockImpl(alias F, Flags...)(
            Offset start, Offset length, Flags flags)
        {
            import std.conv : to;

            immutable ULARGE_INTEGER
                liStart = {QuadPart: start.to!ulong},
                liLength = {QuadPart: length.to!ulong};

            OVERLAPPED overlapped = {
                Offset: liStart.LowPart,
                OffsetHigh: liStart.HighPart,
                hEvent: null,
            };

            return F(_h, flags, 0, liLength.LowPart, liLength.HighPart,
                &overlapped);
        }
    }

    /**
     * Locks the specified file segment. If the file segment is already locked
     * by another process, waits until the existing lock is released.
     *
     * Note that this is a $(I per-process) lock. This locking mechanism should
     * not be used for thread-level synchronization.
     */
    void lock(LockType lockType = LockType.readWrite,
        Offset start = 0, Offset length = Offset.max)
    in { assert(isOpen); }
    body
    {
        version (Posix)
        {
            sysEnforce(
                lockImpl(F_SETLKW,
                    lockType == LockType.readWrite ? F_WRLCK : F_RDLCK,
                    start, length,
                ) != -1, "Failed to lock file"
            );
        }
        else version (Windows)
        {
            sysEnforce(
                lockImpl!LockFileEx(
                    start, length,
                    lockType == LockType.readWrite ? LOCKFILE_EXCLUSIVE_LOCK : 0
                ), "Failed to lock file"
            );
        }
    }

    /**
     * Like $(D lock), but returns false immediately if the lock is held by
     * another process. Returns true if the specified region in the file was
     * successfully locked.
     */
    bool tryLock(LockType lockType = LockType.readWrite,
        Offset start = 0, Offset length = Offset.max)
    in { assert(isOpen); }
    body
    {
        version (Posix)
        {
            import core.stdc.errno;

            // Set the lock, return immediately if it's being held by another
            // process.
            if (lockImpl(F_SETLK,
                    lockType == LockType.readWrite ? F_WRLCK : F_RDLCK,
                    start, length) != 0
                )
            {
                // Is another process is holding the lock?
                if (errno == EACCES || errno == EAGAIN)
                    return false;
                else
                    sysEnforce(false, "Failed to lock file");
            }

            return true;
        }
        else version (Windows)
        {
            immutable flags = LOCKFILE_FAIL_IMMEDIATELY | (
                (lockType == LockType.readWrite) ? LOCKFILE_EXCLUSIVE_LOCK : 0);
            if (!lockImpl!LockFileEx(start, length, flags))
            {
                if (GetLastError() == ERROR_IO_PENDING ||
                    GetLastError() == ERROR_LOCK_VIOLATION)
                    return false;
                else
                    sysEnforce(false, "Failed to lock file");
            }

            return true;
        }
    }

    void unlock(Offset start = 0, Offset length = Offset.max)
    in { assert(isOpen); }
    body
    {
        version (Posix)
        {
            sysEnforce(
                lockImpl(F_SETLK, F_UNLCK, start, length) != -1,
                "Failed to lock file"
            );
        }
        else version (Windows)
        {
            sysEnforce(lockImpl!UnlockFileEx(start, length),
                    "Failed to unlock file");
        }
    }

    /**
     * Flushes all modified cached data of the file to disk. This includes data
     * written to the file as well as meta data (e.g., last modified time, last
     * access time).
     */
    void flush()
    in { assert(isOpen); }
    body
    {
        version (Posix)
        {
            sysEnforce(fsync(_h) == 0);
        }
        else version (Windows)
        {
            sysEnforce(FlushFileBuffers(_h) != 0);
        }
    }

    /**
     * Like $(D sync()), but does not flush meta data.
     *
     * NOTE: On Windows, this is exactly the same as $(D sync()).
     */
    void flushData()
    in { assert(isOpen); }
    body
    {
        version (Posix)
        {
            sysEnforce(fdatasync(_h) == 0);
        }
        else version (Windows)
        {
            sysEnforce(FlushFileBuffers(_h) != 0);
        }
    }


    /**
     * Copies the rest of this file to the other. The positions of both files
     * are appropriately incremented, as if one called read()/write() to copy
     * the file. The number of copied bytes is returned.
     */
    version (linux)
    size_t copyTo()(auto ref File other, size_t n = size_t.max/2-1)
    {
        immutable written = .sendfile(other._h, _h, null, n);
        sysEnforce(written >= 0, "Failed to copy file.");
        return written;
    }

    version (linux)
    unittest
    {
        import std.conv : to;

        auto a = tempFile();
        auto b = tempFile();
        immutable s = "This will be copied to the other file.";
        a.write(s);
        a.position = 0;
        a.copyTo(b);
        assert(a.position == s.length);

        b.position = 0;

        char[s.length] buf;
        assert(b.read(buf) == s.length);
        assert(buf == s);
    }

    /* TODO: Add function to get disk sector size for the file. Use
     * GetFileInformationByHandleEx with FileStorageInfo. See
     * http://msdn.microsoft.com/en-us/library/windows/desktop/hh447302(v=vs.85).aspx
     */
}

unittest
{
    static assert(isSource!File);
    static assert(isSink!File);
    static assert(isSeekable!File);
}

version (unittest)
{
    /**
     * Generates a file name for testing and attempts to delete it on
     * destruction.
     */
    auto testFile(string file = __FILE__, size_t line = __LINE__)
    {
        import std.conv : text;
        import std.path : baseName;
        import std.file : tempDir;

        static struct TestFile
        {
            string name;

            alias name this;

            ~this()
            {
                // Don't care if this fails.
                try .file.remove(name); catch (Exception e) {}
            }
        }

        return TestFile(text(tempDir, "/.deleteme-", baseName(file), ".", line));
    }
}