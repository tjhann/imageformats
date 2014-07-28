// Copyright (c) 2014 Tero Hänninen
// Boost Software License - Version 1.0 - August 17th, 2003
module image.image;

import std.string;  // toLower, lastIndexOf

enum ColFmt : int {
    Unknown = 0,
    Y = 1,
    YA,
    RGB,
    RGBA,
    BGR,
    BGRA,
}

class ImageException : Exception {
   @safe pure const
   this(string msg, string file = __FILE__, size_t line = __LINE__) {
       super(msg, file, line);
   }
}

struct ImageInfo {
    int w;
    int h;
    ColFmt fmt;
}

struct Image {
    int width;      alias w = width;
    int height;     alias h = height;
    ColFmt fmt;
    ubyte[] data;

    @property string toString() const {
        import std.conv;
        return text("width: ", width, " height: ", height, " fmt: ", fmt);
    }
}

ImageInfo read_image_info(in char[] filename) {
    const(char)[] ext = extract_extension_lowercase(filename);

    if (ext in register) {
        ImageIOFuncs funcs = register[ext];
        if (funcs.read_info is null)
            throw new ImageException("null function pointer");
        auto stream = new InStream(filename);
        scope(exit) stream.close();
        return funcs.read_info(stream);
    }

    throw new ImageException("unknown image extension/type");
}

Image read_image(in char[] filename, int req_chans = 0) {
    const(char)[] ext = extract_extension_lowercase(filename);

    if (ext in register) {
        ImageIOFuncs funcs = register[ext];
        if (funcs.read_image is null)
            throw new ImageException("null function pointer");
        Image image;
        auto stream = new InStream(filename);
        scope(exit) stream.close();
        image.data = funcs.read_image(stream, image.w, image.h, image.fmt, req_chans);
        return image;
    }

    throw new ImageException("unknown image extension/type");
}

private const(char)[] extract_extension_lowercase(in char[] filename) {
    ptrdiff_t di = filename.lastIndexOf('.');
    return (0 < di && di+1 < filename.length) ? filename[di+1..$].toLower() : "";
}

// --------------------------------------------------------------------------------
// Register

struct ImageIOFuncs {
    ubyte[] function(InStream s, out int w, out int h, out int c, int reqc) read_image;
    ImageInfo function(InStream s) read_info;
}
package static ImageIOFuncs[string] register;

// --------------------------------------------------------------------------------
// Conversions

package pure
void function(in ubyte[] src, ubyte[] tgt) get_converter(int src_chans, int tgt_chans) {
    if (src_chans == tgt_chans)
        return &copy_line;
    switch (combo(src_chans, tgt_chans)) with (ColFmt) {
        case combo(Y, YA)      : return &Y_to_YA;
        case combo(Y, RGB)     : return &Y_to_RGB;
        case combo(Y, RGBA)    : return &Y_to_RGBA;
        case combo(YA, Y)      : return &YA_to_Y;
        case combo(YA, RGB)    : return &YA_to_RGB;
        case combo(YA, RGBA)   : return &YA_to_RGBA;
        case combo(RGB, Y)     : return &RGB_to_Y;
        case combo(RGB, YA)    : return &RGB_to_YA;
        case combo(RGB, RGBA)  : return &RGB_to_RGBA;
        case combo(RGBA, Y)    : return &RGBA_to_Y;
        case combo(RGBA, YA)   : return &RGBA_to_YA;
        case combo(RGBA, RGB)  : return &RGBA_to_RGB;
        case combo(BGR, Y)     : return &BGR_to_Y;
        case combo(BGR, YA)    : return &BGR_to_YA;
        case combo(BGR, RGB)   : return &BGR_to_RGB;
        case combo(BGR, RGBA)  : return &BGR_to_RGBA;
        case combo(BGRA, Y)    : return &BGRA_to_Y;
        case combo(BGRA, YA)   : return &BGRA_to_YA;
        case combo(BGRA, RGB)  : return &BGRA_to_RGB;
        case combo(BGRA, RGBA) : return &BGRA_to_RGBA;
        default                : throw new ImageException("internal error");
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

package void Y_to_RGB(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (long k, t;   k < src.length;   k+=1, t+=3)
        tgt[t .. t+3] = src[k];
}

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

package void YA_to_RGB(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (long k, t;   k < src.length;   k+=2, t+=3)
        tgt[t .. t+3] = src[k];
}

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

package void BGR_to_RGB(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (long k;   k < src.length;   k+=3) {
        tgt[k  ] = src[k+2];
        tgt[k+1] = src[k+1];
        tgt[k+2] = src[k  ];
    }
}

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

package void BGRA_to_RGB(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (long k, t;   k < src.length;   k+=4, t+=3) {
        tgt[t  ] = src[k+2];
        tgt[t+1] = src[k+1];
        tgt[t+2] = src[k  ];
    }
}

package void BGRA_to_RGBA(in ubyte[] src, ubyte[] tgt) pure nothrow {
    for (long k, t;   k < src.length;   k+=4, t+=4) {
        tgt[t  ] = src[k+2];
        tgt[t+1] = src[k+1];
        tgt[t+2] = src[k  ];
        tgt[t+3] = src[k+3];
    }
}

// --------------------------------------------------------------------------------
// Temporary stream (std.stream is severely broken)

import std.stdio;

package class InStream {
    private {
        File f;
    }

    this(in char[] filename) {
        this.f = File(filename.idup, "rb");
    }

    void readExact(ubyte[] block, size_t bytes) {
        if (bytes == 0)
            return;
        if (block.length < bytes)
            throw new ImageException("not enough space in buffer");
        size_t rlen = f.rawRead(block[0..bytes]).length;
        if (rlen != bytes)
            throw new ImageException("not enough data");
    }

    size_t readBlock(ubyte[] block, size_t wanted = size_t.max) nothrow {
        if (!block.length || wanted == 0)
            return 0;

        if (wanted > block.length)
            wanted = block.length;

        try {
            return f.rawRead(block[0..wanted]).length;
        } catch {
            return 0;
        }
    }

    void close() {
        f.close();
    }
}

package class OutStream {
    private {
        File f;
    }

    this(in char[] filename) {
        this.f = File(filename.idup, "w");
    }

    void writeBlock(const(ubyte)[] block) {
        f.rawWrite(block);
    }

    void flush_and_close() {
        f.close();
    }
}
