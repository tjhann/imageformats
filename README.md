# imageformats  [![Build Status](https://travis-ci.org/lgvz/imageformats.svg)](https://travis-ci.org/lgvz/imageformats)

- Returned image data is 8-bit except PNG can also return 16-bit.
- Image data can be converted to Y, YA, RGB or RGBA.

| Format | Decoder            | Encoder                           |
| ---    | ---                | ---                               |
| png    | 8-bit, 16-bit      | 8-bit non-paletted non-interlaced |
| tga    | 8-bit non-paletted | 8-bit non-paletted                |
| bmp    | 8-bit              | 8-bit uncompressed                |
| jpeg   | baseline           | nope                              |

```D
import imageformats;

void main() {
    IFImage i0 = read_image("peruna.png");
    IFImage i1 = read_image("peruna.png", ColFmt.YA);   // convert
    IFImage i2 = read_image("peruna.png", ColFmt.RGB);

    write_image("peruna.tga", i0.w, i0.h, i0.pixels);
    write_image("peruna.tga", i0.w, i0.h, i0.pixels, ColFmt.RGBA);

    int w, h, chans;
    read_image_info("peruna.png", w, h, chans);     // no decoding

    // format specific functions
    PNG_Header hdr = read_png_header("peruna.png");
    IFImage i3 = read_jpeg("porkkana.jpg");
    write_tga("porkkana.tga", i3.w, i3.h, i3.pixels);
}
```
