**Image loading and saving**
- returned image data is always 8-bit (Y/YA/RGB/RGBA)
- no image processing (plan is to keep this stuff out)
- bloat can be avoided by importing only needed formats

| Format | Decoder            | Encoder                           |
| ---    | ---                | ---                               |
| png    | 8-bit non-paletted | 8-bit non-interlaced non-paletted |
| tga    | color & monochrome | color & monochrome                |
| jpeg   | baseline           | nope                              |

**It's trivial:**
```D
import std.stdio;   // File
// import all formats:
import imageformats;
// ...or import only what you need:
import imageformats.png;
import imageformats.tga;

void main() {
    long w, h;
    int chans;

    // w and h will be set to width and heigth
    // chans will be set to number of channels in returned data
    // optional last argument defines conversion
    ubyte[] data0 = read_image("peruna.png", w, h, chans);
    ubyte[] data1 = read_image("peruna.png", w, h, chans, ColFmt.YA);
    ubyte[] data2 = read_image("peruna.png", w, h, chans, ColFmt.RGB);

    write_image("peruna.tga", w, h, data0);
    write_image("peruna.tga", w, h, data0, ColFmt.RGBA);

    read_image_info("peruna.png", w, h, chans);

    // there are also format specific functions
    PNG_Header hdr = read_png_header("peruna.png"); // get detailed info
    ubyte[] data3 = read_png("peruna.png", w, h, chans);
    write_tga("peruna.tga", w, h, data3);

    // can also pass a File to all the non-generic functions
    auto f = File("peruna.tga", "wb");
    scope(exit) f.close();
    write_png(f, w, h, data3);
    f.flush();
}
```
