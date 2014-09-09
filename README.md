**Image loading and saving**
- returned image data is always 8-bit (Y/YA/RGB/RGBA)
- no image processing (this stuff will be kept out)
- not optimal for 32-bit systems

| Format | Decoder            | Encoder                           |
| ---    | ---                | ---                               |
| png    | 8-bit              | 8-bit non-paletted non-interlaced |
| tga    | 8-bit non-paletted | 8-bit non-paletted                |
| jpeg   | baseline           | nope                              |

**Let me show you:**
```D
import std.stdio;   // File
import imageformats;

void main() {
    // optional last argument defines conversion
    long w, h, chans;
    ubyte[] pixels = read_image("peruna.png", w, h, chans);
    //ubyte[] pixels = read_image("peruna.png", w, h, chans, ColFmt.YA);
    //ubyte[] pixels = read_image("peruna.png", w, h, chans, ColFmt.RGB);

    write_image("peruna.tga", w, h, pixels);
    write_image("peruna.tga", w, h, pixels, ColFmt.RGBA);

    // get basic info without decoding
    read_image_info("peruna.png", w, h, chans);

    // there are also format specific functions
    PNG_Header hdr = read_png_header("peruna.png"); // get detailed info
    ubyte[] idat = read_jpeg("porkkana.jpg", w, h, chans, ColFmt.Y);
    write_tga("porkkana.tga", w, h, idat);
}
```
