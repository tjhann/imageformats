// Copyright (c) 2014 Tero Hänninen
// Boost Software License - Version 1.0 - August 17th, 2003
module imageformats.common;

import std.stdio;   // File
import std.string;  // toLower, lastIndexOf

class ImageIOException : Exception {
   @safe pure const
   this(string msg, string file = __FILE__, size_t line = __LINE__) {
       super(msg, file, line);
   }
}

struct IF_Image {
    long w, h;
    ColFmt chans;
    AlphaType alpha_type;
    ubyte[] data;
}

enum ColFmt {
    Y = 1,
    YA = 2,
    RGB = 3,
    RGBA = 4,
}

enum AlphaType {
    Plain,
    Premul,
    Other
}

// chans is set to zero if num of channels is unknown
void read_image_info(in char[] filename, out int w, out int h, out int chans) {
    const(char)[] ext = extract_extension_lowercase(filename);

    if (ext in register) {
        ImageIOFuncs funcs = register[ext];
        if (funcs.read_info is null)
            throw new ImageIOException("null function pointer");
        auto stream = File(filename.idup, "rb");
        scope(exit) stream.close();
        funcs.read_info(stream, w, h, chans);
        return;
    }

    throw new ImageIOException("unknown image extension/type");
}

IF_Image read_image(in char[] filename, int req_chans = 0) {
    const(char)[] ext = extract_extension_lowercase(filename);

    if (ext in register) {
        ImageIOFuncs funcs = register[ext];
        if (funcs.read_image is null)
            throw new ImageIOException("null function pointer");
        auto stream = File(filename.idup, "rb");
        scope(exit) stream.close();
        return funcs.read_image(stream, req_chans);
    }

    throw new ImageIOException("unknown image extension/type");
}

void write_image(in char[] filename, long w, long h, in ubyte[] data, int req_chans = 0) {
    const(char)[] ext = extract_extension_lowercase(filename);

    if (ext in register) {
        ImageIOFuncs funcs = register[ext];
        if (funcs.write_image is null)
            throw new ImageIOException("null function pointer");
        auto stream = File(filename.idup, "wb");
        scope(exit) stream.close();
        funcs.write_image(stream, w, h, data, req_chans);
        return;
    }

    throw new ImageIOException("unknown image extension/type");
}

private const(char)[] extract_extension_lowercase(in char[] filename) {
    ptrdiff_t di = filename.lastIndexOf('.');
    return (0 < di && di+1 < filename.length) ? filename[di+1..$].toLower() : "";
}

// --------------------------------------------------------------------------------
// Register

package struct ImageIOFuncs {
    IF_Image function(File s, int req_chans) read_image;
    void function(File s, long w, long h, in ubyte[] data, int req_chans) write_image;
    void function(File s, out int w, out int h, out int c) read_info;
}
package static ImageIOFuncs[string] register;

package void readExact(File stream, ubyte[] buffer, size_t bytes) {
    auto slice = stream.rawRead(buffer[0..bytes]);
    if (slice.length != bytes)
        throw new Exception("not enough data");
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

package pure
void function(in ubyte[] src, ubyte[] tgt) get_converter(int src_chans, int tgt_chans) {
    if (src_chans == tgt_chans)
        return &copy_line;
    switch (combo(src_chans, tgt_chans)) with (_ColFmt) {
        case combo(Y, YA)      : return &Y_to_YA;
        case combo(Y, RGB)     : return &Y_to_RGB;
        case combo(Y, RGBA)    : return &Y_to_RGBA;
        case combo(Y, BGR)     : return &Y_to_BGR;
        case combo(Y, BGRA)    : return &Y_to_BGRA;
        case combo(YA, Y)      : return &YA_to_Y;
        case combo(YA, RGB)    : return &YA_to_RGB;
        case combo(YA, RGBA)   : return &YA_to_RGBA;
        case combo(YA, BGR)    : return &YA_to_BGR;
        case combo(YA, BGRA)   : return &YA_to_BGRA;
        case combo(RGB, Y)     : return &RGB_to_Y;
        case combo(RGB, YA)    : return &RGB_to_YA;
        case combo(RGB, RGBA)  : return &RGB_to_RGBA;
        case combo(RGB, BGR)   : return &RGB_to_BGR;
        case combo(RGB, BGRA)  : return &RGB_to_BGRA;
        case combo(RGBA, Y)    : return &RGBA_to_Y;
        case combo(RGBA, YA)   : return &RGBA_to_YA;
        case combo(RGBA, RGB)  : return &RGBA_to_RGB;
        case combo(RGBA, BGR)  : return &RGBA_to_BGR;
        case combo(RGBA, BGRA) : return &RGBA_to_BGRA;
        case combo(BGR, Y)     : return &BGR_to_Y;
        case combo(BGR, YA)    : return &BGR_to_YA;
        case combo(BGR, RGB)   : return &BGR_to_RGB;
        case combo(BGR, RGBA)  : return &BGR_to_RGBA;
        case combo(BGRA, Y)    : return &BGRA_to_Y;
        case combo(BGRA, YA)   : return &BGRA_to_YA;
        case combo(BGRA, RGB)  : return &BGRA_to_RGB;
        case combo(BGRA, RGBA) : return &BGRA_to_RGBA;
        default                : throw new ImageIOException("internal error");
    }
}

private int combo(int a, int b) pure nothrow {
    return a*16 + b;
}

package void copy_line(in ubyte[] src, ubyte[] tgt) pure nothrow {
    tgt[0..$] = src[0..$];
}

package ubyte luminance(ubyte r, ubyte g, ubyte b) pure nothrow {
    return cast(ubyte) (0.21*r + 0.64*g + 0.15*b); // somewhat arbitrary weights
}

package void Y_to_YA(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (long k, t;   k < src.length;   k+=1, t+=2) {
        tgt[t] = src[k];
        tgt[t+1] = 255;
    }
}

package alias Y_to_BGR = Y_to_RGB;
package void Y_to_RGB(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (long k, t;   k < src.length;   k+=1, t+=3)
        tgt[t .. t+3] = src[k];
}

package alias Y_to_BGRA = Y_to_RGBA;
package void Y_to_RGBA(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (long k, t;   k < src.length;   k+=1, t+=4) {
        tgt[t .. t+3] = src[k];
        tgt[t+3] = 255;
    }
}

package void YA_to_Y(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (long k, t;   k < src.length;   k+=2, t+=1)
        tgt[t] = src[k];
}

package alias YA_to_BGR = YA_to_RGB;
package void YA_to_RGB(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (long k, t;   k < src.length;   k+=2, t+=3)
        tgt[t .. t+3] = src[k];
}

package alias YA_to_BGRA = YA_to_RGBA;
package void YA_to_RGBA(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (long k, t;   k < src.length;   k+=2, t+=4) {
        tgt[t .. t+3] = src[k];
        tgt[t+3] = src[k+1];
    }
}

package void RGB_to_Y(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (long k, t;   k < src.length;   k+=3, t+=1)
        tgt[t] = luminance(src[k], src[k+1], src[k+2]);
}

package void RGB_to_YA(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (long k, t;   k < src.length;   k+=3, t+=2) {
        tgt[t] = luminance(src[k], src[k+1], src[k+2]);
        tgt[t+1] = 255;
    }
}

package void RGB_to_RGBA(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (long k, t;   k < src.length;   k+=3, t+=4) {
        tgt[t .. t+3] = src[k .. k+3];
        tgt[t+3] = 255;
    }
}

package void RGBA_to_Y(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (long k, t;   k < src.length;   k+=4, t+=1)
        tgt[t] = luminance(src[k], src[k+1], src[k+2]);
}

package void RGBA_to_YA(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (long k, t;   k < src.length;   k+=4, t+=2) {
        tgt[t] = luminance(src[k], src[k+1], src[k+2]);
        tgt[t+1] = src[k+3];
    }
}

package void RGBA_to_RGB(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (long k, t;   k < src.length;   k+=4, t+=3)
        tgt[t .. t+3] = src[k .. k+3];
}

package void BGR_to_Y(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (long k, t;   k < src.length;   k+=3, t+=1)
        tgt[t] = luminance(src[k+2], src[k+1], src[k+1]);
}

package void BGR_to_YA(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (long k, t;   k < src.length;   k+=3, t+=2) {
        tgt[t] = luminance(src[k+2], src[k+1], src[k+1]);
        tgt[t+1] = 255;
    }
}

package alias RGB_to_BGR = BGR_to_RGB;
package void BGR_to_RGB(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (long k;   k < src.length;   k+=3) {
        tgt[k  ] = src[k+2];
        tgt[k+1] = src[k+1];
        tgt[k+2] = src[k  ];
    }
}

package alias RGB_to_BGRA = BGR_to_RGBA;
package void BGR_to_RGBA(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (long k, t;   k < src.length;   k+=3, t+=4) {
        tgt[t  ] = src[k+2];
        tgt[t+1] = src[k+1];
        tgt[t+2] = src[k  ];
        tgt[t+3] = 255;
    }
}

package void BGRA_to_Y(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (long k, t;   k < src.length;   k+=4, t+=1)
        tgt[t] = luminance(src[k+2], src[k+1], src[k]);
}

package void BGRA_to_YA(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (long k, t;   k < src.length;   k+=4, t+=2) {
        tgt[t] = luminance(src[k+2], src[k+1], src[k]);
        tgt[t+1] = 255;
    }
}

package alias RGBA_to_BGR = BGRA_to_RGB;
package void BGRA_to_RGB(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (long k, t;   k < src.length;   k+=4, t+=3) {
        tgt[t  ] = src[k+2];
        tgt[t+1] = src[k+1];
        tgt[t+2] = src[k  ];
    }
}

package alias RGBA_to_BGRA = BGRA_to_RGBA;
package void BGRA_to_RGBA(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (long k, t;   k < src.length;   k+=4, t+=4) {
        tgt[t  ] = src[k+2];
        tgt[t+1] = src[k+1];
        tgt[t+2] = src[k  ];
        tgt[t+3] = src[k+3];
    }
}
