**Image loading and saving**
- returned image data is always 8-bit (Y/YA/RGB/RGBA)
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
    IFImage im = read_image("peruna.png");
    IFImage im2 = read_image("peruna.png", ColFmt.YA);
    IFImage im3 = read_image("peruna.png", ColFmt.RGB);

    write_image("peruna.tga", im.w, im.h, im.pixels);
    write_image("peruna.tga", im.w, im.h, im.pixels, ColFmt.RGBA);

    // get basic info without decoding
    long w, h, chans;
    read_image_info("peruna.png", w, h, chans);

    // there are also format specific functions
    PNG_Header hdr = read_png_header("peruna.png"); // get detailed info
    IFImage im4 = read_jpeg("porkkana.jpg");
    write_tga("porkkana.tga", im4.w, im4.h, im4.pixels);
}
```
