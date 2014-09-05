**Image loading and saving**
- returned image data is always 8-bit (Y/YA/RGB/RGBA)
- no image processing (plan is to keep this stuff out)

| Format | Decoder            | Encoder                           |
| ---    | ---                | ---                               |
| png    | 8-bit non-paletted | 8-bit non-interlaced non-paletted |
| tga    | 8-bit non-paletted | 8-bit non-paletted                |
| jpeg   | baseline           | nope                              |

**Let me show you:**
```D
import std.stdio;   // File
import imageformats;

void main() {
    // optional last argument defines conversion
    IF_Image a = read_image("peruna.png");
    IF_Image b = read_image("peruna.png", ColFmt.YA);
    IF_Image c = read_image("peruna.png", ColFmt.RGB);

    write_image("peruna.tga", a.w, a.h, a.data);
    write_image("peruna.tga", a.w, a.h, a.data, ColFmt.RGBA);

    int w, h, chans;
    read_image_info("peruna.png", w, h, chans);

    // there are also format specific functions
    PNG_Header hdr = read_png_header("peruna.png"); // get detailed info
    IF_Image d = read_png("peruna.png");
    write_tga("peruna.tga", d.w, d.h, d.data);

    // can also pass a File to all the non-generic functions
    auto f = File("peruna.tga", "wb");
    scope(exit) f.close();
    write_png(f, d.w, d.h, d.data);
}
```
