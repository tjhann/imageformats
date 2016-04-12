// Copyright (c) 2014 Tero Hänninen
// Boost Software License - Version 1.0 - August 17th, 2003
module imageformats;

import std.stdio;    // File
import std.string;  // toLower, lastIndexOf
public import imageformats.png;
public import imageformats.tga;
public import imageformats.bmp;
public import imageformats.jpeg;

/// Image
struct IFImage {
    int         w, h;
    ColFmt      c;
    ubyte[]     pixels;
}

/// Image
struct IFImage16 {
    int         w, h;
    ColFmt      c;
    ushort[]    pixels;
}

/// Color format
enum ColFmt {
    Y = 1,
    YA = 2,
    RGB = 3,
    RGBA = 4,
}

/// Reads an image from file.
IFImage read_image(in char[] file, long req_chans = 0) {
    scope reader = new FileReader(file);
    return read_image_from_reader(reader, req_chans);
}

/// Reads an image in memory.
IFImage read_image_from_mem(in ubyte[] source, long req_chans = 0) {
    scope reader = new MemReader(source);
    return read_image_from_reader(reader, req_chans);
}

/// Writes an image to file.
void write_image(in char[] file, long w, long h, in ubyte[] data, long req_chans = 0) {
    const(char)[] ext = extract_extension_lowercase(file);

    void function(Writer, long, long, in ubyte[], long) write_image;
    switch (ext) {
        case "png": write_image = &write_png; break;
        case "tga": write_image = &write_tga; break;
        case "bmp": write_image = &write_bmp; break;
        default: throw new ImageIOException("unknown image extension/type");
    }
    scope writer = new FileWriter(file);
    write_image(writer, w, h, data, req_chans);
}

/// Returns basic info about an image.
/// If number of channels is unknown chans is set to zero.
void read_image_info(in char[] file, out int w, out int h, out int chans) {
    scope reader = new FileReader(file);
    try {
        return read_png_info(reader, w, h, chans);
    } catch {
        reader.seek(0, SEEK_SET);
    }
    try {
        return read_jpeg_info(reader, w, h, chans);
    } catch {
        reader.seek(0, SEEK_SET);
    }
    try {
        return read_bmp_info(reader, w, h, chans);
    } catch {
        reader.seek(0, SEEK_SET);
    }
    try {
        return read_tga_info(reader, w, h, chans);
    } catch {
        reader.seek(0, SEEK_SET);
    }
    throw new ImageIOException("unknown image type");
}

///
class ImageIOException : Exception {
   @safe pure const
   this(string msg, string file = __FILE__, size_t line = __LINE__) {
       super(msg, file, line);
   }
}

private:

IFImage read_image_from_reader(Reader reader, long req_chans) {
    if (detect_png(reader)) return read_png(reader, req_chans);
    if (detect_jpeg(reader)) return read_jpeg(reader, req_chans);
    if (detect_bmp(reader)) return read_bmp(reader, req_chans);
    if (detect_tga(reader)) return read_tga(reader, req_chans);
    throw new ImageIOException("unknown image type");
}

// --------------------------------------------------------------------------------
// Conversions

package enum _ColFmt : int {
    Unknown = 0,
    Y = 1,
    YA,
    RGB,
    RGBA,
    BGR,
    BGRA,
}

package alias LineConv(T) = void function(in T[] src, T[] tgt);

package LineConv!T get_converter(T)(long src_chans, long tgt_chans) pure {
    long combo(long a, long b) pure nothrow { return a*16 + b; }

    if (src_chans == tgt_chans)
        return &copy_line!T;

    switch (combo(src_chans, tgt_chans)) with (_ColFmt) {
        case combo(Y, YA)      : return &Y_to_YA!T;
        case combo(Y, RGB)     : return &Y_to_RGB!T;
        case combo(Y, RGBA)    : return &Y_to_RGBA!T;
        case combo(Y, BGR)     : return &Y_to_BGR!T;
        case combo(Y, BGRA)    : return &Y_to_BGRA!T;
        case combo(YA, Y)      : return &YA_to_Y!T;
        case combo(YA, RGB)    : return &YA_to_RGB!T;
        case combo(YA, RGBA)   : return &YA_to_RGBA!T;
        case combo(YA, BGR)    : return &YA_to_BGR!T;
        case combo(YA, BGRA)   : return &YA_to_BGRA!T;
        case combo(RGB, Y)     : return &RGB_to_Y!T;
        case combo(RGB, YA)    : return &RGB_to_YA!T;
        case combo(RGB, RGBA)  : return &RGB_to_RGBA!T;
        case combo(RGB, BGR)   : return &RGB_to_BGR!T;
        case combo(RGB, BGRA)  : return &RGB_to_BGRA!T;
        case combo(RGBA, Y)    : return &RGBA_to_Y!T;
        case combo(RGBA, YA)   : return &RGBA_to_YA!T;
        case combo(RGBA, RGB)  : return &RGBA_to_RGB!T;
        case combo(RGBA, BGR)  : return &RGBA_to_BGR!T;
        case combo(RGBA, BGRA) : return &RGBA_to_BGRA!T;
        case combo(BGR, Y)     : return &BGR_to_Y!T;
        case combo(BGR, YA)    : return &BGR_to_YA!T;
        case combo(BGR, RGB)   : return &BGR_to_RGB!T;
        case combo(BGR, RGBA)  : return &BGR_to_RGBA!T;
        case combo(BGRA, Y)    : return &BGRA_to_Y!T;
        case combo(BGRA, YA)   : return &BGRA_to_YA!T;
        case combo(BGRA, RGB)  : return &BGRA_to_RGB!T;
        case combo(BGRA, RGBA) : return &BGRA_to_RGBA!T;
        default                : throw new ImageIOException("internal error");
    }
}

void copy_line(T)(in T[] src, T[] tgt) pure nothrow {
    tgt[0..$] = src[0..$];
}

T luminance(T)(T r, T g, T b) pure nothrow {
    return cast(T) (0.21*r + 0.64*g + 0.15*b); // somewhat arbitrary weights
}

void Y_to_YA(T)(in T[] src, T[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=1, t+=2) {
        tgt[t] = src[k];
        tgt[t+1] = T.max;
    }
}

alias Y_to_BGR = Y_to_RGB;
void Y_to_RGB(T)(in T[] src, T[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=1, t+=3)
        tgt[t .. t+3] = src[k];
}

alias Y_to_BGRA = Y_to_RGBA;
void Y_to_RGBA(T)(in T[] src, T[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=1, t+=4) {
        tgt[t .. t+3] = src[k];
        tgt[t+3] = T.max;
    }
}

void YA_to_Y(T)(in T[] src, T[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=2, t+=1)
        tgt[t] = src[k];
}

alias YA_to_BGR = YA_to_RGB;
void YA_to_RGB(T)(in T[] src, T[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=2, t+=3)
        tgt[t .. t+3] = src[k];
}

alias YA_to_BGRA = YA_to_RGBA;
void YA_to_RGBA(T)(in T[] src, T[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=2, t+=4) {
        tgt[t .. t+3] = src[k];
        tgt[t+3] = src[k+1];
    }
}

void RGB_to_Y(T)(in T[] src, T[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=3, t+=1)
        tgt[t] = luminance(src[k], src[k+1], src[k+2]);
}

void RGB_to_YA(T)(in T[] src, T[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=3, t+=2) {
        tgt[t] = luminance(src[k], src[k+1], src[k+2]);
        tgt[t+1] = T.max;
    }
}

void RGB_to_RGBA(T)(in T[] src, T[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=3, t+=4) {
        tgt[t .. t+3] = src[k .. k+3];
        tgt[t+3] = T.max;
    }
}

void RGBA_to_Y(T)(in T[] src, T[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=4, t+=1)
        tgt[t] = luminance(src[k], src[k+1], src[k+2]);
}

void RGBA_to_YA(T)(in T[] src, T[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=4, t+=2) {
        tgt[t] = luminance(src[k], src[k+1], src[k+2]);
        tgt[t+1] = src[k+3];
    }
}

void RGBA_to_RGB(T)(in T[] src, T[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=4, t+=3)
        tgt[t .. t+3] = src[k .. k+3];
}

void BGR_to_Y(T)(in T[] src, T[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=3, t+=1)
        tgt[t] = luminance(src[k+2], src[k+1], src[k+1]);
}

void BGR_to_YA(T)(in T[] src, T[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=3, t+=2) {
        tgt[t] = luminance(src[k+2], src[k+1], src[k+1]);
        tgt[t+1] = T.max;
    }
}

alias RGB_to_BGR = BGR_to_RGB;
void BGR_to_RGB(T)(in T[] src, T[] tgt) pure nothrow {
    for (size_t k;   k < src.length;   k+=3) {
        tgt[k  ] = src[k+2];
        tgt[k+1] = src[k+1];
        tgt[k+2] = src[k  ];
    }
}

alias RGB_to_BGRA = BGR_to_RGBA;
void BGR_to_RGBA(T)(in T[] src, T[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=3, t+=4) {
        tgt[t  ] = src[k+2];
        tgt[t+1] = src[k+1];
        tgt[t+2] = src[k  ];
        tgt[t+3] = T.max;
    }
}

void BGRA_to_Y(T)(in T[] src, T[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=4, t+=1)
        tgt[t] = luminance(src[k+2], src[k+1], src[k]);
}

void BGRA_to_YA(T)(in T[] src, T[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=4, t+=2) {
        tgt[t] = luminance(src[k+2], src[k+1], src[k]);
        tgt[t+1] = T.max;
    }
}

alias RGBA_to_BGR = BGRA_to_RGB;
void BGRA_to_RGB(T)(in T[] src, T[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=4, t+=3) {
        tgt[t  ] = src[k+2];
        tgt[t+1] = src[k+1];
        tgt[t+2] = src[k  ];
    }
}

alias RGBA_to_BGRA = BGRA_to_RGBA;
void BGRA_to_RGBA(T)(in T[] src, T[] tgt) pure nothrow {
    for (size_t k, t;   k < src.length;   k+=4, t+=4) {
        tgt[t  ] = src[k+2];
        tgt[t+1] = src[k+1];
        tgt[t+2] = src[k  ];
        tgt[t+3] = src[k+3];
    }
}

// --------------------------------------------------------------------------------

package interface Reader {
    void readExact(ubyte[], size_t);
    void seek(ptrdiff_t, int);
}

package interface Writer {
    void rawWrite(in ubyte[]);
    void flush();
}

package class FileReader : Reader {
    this(in char[] filename) {
        this(File(filename.idup, "rb"));
    }

    this(File f) {
        if (!f.isOpen) throw new ImageIOException("File not open");
        this.f = f;
    }

    void readExact(ubyte[] buffer, size_t bytes) {
        auto slice = this.f.rawRead(buffer[0..bytes]);
        if (slice.length != bytes)
            throw new Exception("not enough data");
    }

    void seek(ptrdiff_t offset, int origin) { this.f.seek(offset, origin); }

    private File f;
}

package class MemReader : Reader {
    this(in ubyte[] source) {
        this.source = source;
    }

    void readExact(ubyte[] buffer, size_t bytes) {
        if (source.length - cursor < bytes)
            throw new Exception("not enough data");
        buffer[0..bytes] = source[cursor .. cursor+bytes];
        cursor += bytes;
    }

    void seek(ptrdiff_t offset, int origin) {
        switch (origin) {
            case SEEK_SET:
                if (offset < 0 || source.length <= offset)
                    throw new Exception("seek error");
                cursor = offset;
                break;
            case SEEK_CUR:
                ptrdiff_t dst = cursor + offset;
                if (dst < 0 || source.length <= dst)
                    throw new Exception("seek error");
                cursor = dst;
                break;
            case SEEK_END:
                if (0 <= offset || source.length < -offset)
                    throw new Exception("seek error");
                cursor = cast(ptrdiff_t) source.length + offset;
                break;
            default: assert(0);
        }
    }

    private const ubyte[] source;
    private ptrdiff_t cursor;
}

package class FileWriter : Writer {
    this(in char[] filename) {
        this(File(filename.idup, "wb"));
    }

    this(File f) {
        if (!f.isOpen) throw new ImageIOException("File not open");
        this.f = f;
    }

    void rawWrite(in ubyte[] block) { this.f.rawWrite(block); }
    void flush() { this.f.flush(); }

    private File f;
}

package class MemWriter : Writer {
    this() { }

    ubyte[] result() { return buffer; }

    void rawWrite(in ubyte[] block) { this.buffer ~= block; }
    void flush() { }

    private ubyte[] buffer;
}

const(char)[] extract_extension_lowercase(in char[] filename) {
    ptrdiff_t di = filename.lastIndexOf('.');
    return (0 < di && di+1 < filename.length) ? filename[di+1..$].toLower() : "";
}

unittest {
    // The TGA and BMP files are not as varied in format as the PNG files, so
    // not as well tested.
    string png_path = "tests/pngsuite/";
    string tga_path = "tests/pngsuite-tga/";
    string bmp_path = "tests/pngsuite-bmp/";

    auto files = [
        "basi0g08",    // PNG image data, 32 x 32, 8-bit grayscale, interlaced
        "basi2c08",    // PNG image data, 32 x 32, 8-bit/color RGB, interlaced
        "basi3p08",    // PNG image data, 32 x 32, 8-bit colormap, interlaced
        "basi4a08",    // PNG image data, 32 x 32, 8-bit gray+alpha, interlaced
        "basi6a08",    // PNG image data, 32 x 32, 8-bit/color RGBA, interlaced
        "basn0g08",    // PNG image data, 32 x 32, 8-bit grayscale, non-interlaced
        "basn2c08",    // PNG image data, 32 x 32, 8-bit/color RGB, non-interlaced
        "basn3p08",    // PNG image data, 32 x 32, 8-bit colormap, non-interlaced
        "basn4a08",    // PNG image data, 32 x 32, 8-bit gray+alpha, non-interlaced
        "basn6a08",    // PNG image data, 32 x 32, 8-bit/color RGBA, non-interlaced
    ];

    foreach (file; files) {
        //writefln("%s", file);
        auto a = read_image(png_path ~ file ~ ".png", ColFmt.RGBA);
        auto b = read_image(tga_path ~ file ~ ".tga", ColFmt.RGBA);
        auto c = read_image(bmp_path ~ file ~ ".bmp", ColFmt.RGBA);
        assert(a.w == b.w && a.w == c.w);
        assert(a.h == b.h && a.h == c.h);
        assert(a.pixels.length == b.pixels.length && a.pixels.length == c.pixels.length);
        foreach (i; 0 .. a.pixels.length) {
            assert(a.pixels[i] == b.pixels[i], "png/tga");
            assert(a.pixels[i] == c.pixels[i], "png/bmp");
        }
    }
}
