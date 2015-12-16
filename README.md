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
