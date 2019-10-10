# imageformats  [![Build Status](https://travis-ci.org/lgvz/imageformats.svg)](https://travis-ci.org/lgvz/imageformats)

- Returned image data is 8-bit except PNG can also return 16-bit.
- Image data can be converted to Y, YA, RGB or RGBA.
- There's a `@nogc` remake: [imagefmt](https://github.com/lgvz/imagefmt)

**Decoders:**
- PNG. 8-bit and 16-bit interlaced and paletted (+`tRNS` chunk)
- TGA. 8-bit non-paletted
- BMP. 8-bit uncompressed
- JPEG. baseline

**Encoders:**
- PNG. 8-bit non-paletted non-interlaced
- TGA. 8-bit non-paletted rle-compressed
- BMP. 8-bit uncompressed

```D
import imageformats;

void main() {
    IFImage i0 = read_image("peruna.png");
    IFImage i1 = read_image("peruna.png", ColFmt.YA);   // convert
    IFImage i2 = read_image("peruna.png", ColFmt.RGB);

    write_image("peruna.tga", i0.w, i0.h, i0.pixels);
    write_image("peruna.tga", i0.w, i0.h, i0.pixels, ColFmt.RGBA);

    int w, h, chans;
    read_image_info("peruna.png", w, h, chans);

    // format specific functions
    PNG_Header hdr = read_png_header("peruna.png");
    IFImage i3 = read_jpeg("porkkana.jpg");
    write_tga("porkkana.tga", i3.w, i3.h, i3.pixels);
}
```
