"use strict";
var items = [
{"imageformats.png" : "imageformats/png.html"},
{"imageformats.png.PNG_Header" : "imageformats/png/PNG_Header.html"},
{"imageformats.png.read_png_header" : "imageformats/png.html#read_png_header"},
{"imageformats.png.read_png_header_from_mem" : "imageformats/png.html#read_png_header_from_mem"},
{"imageformats.png.read_png" : "imageformats/png.html#read_png"},
{"imageformats.png.read_png_from_mem" : "imageformats/png.html#read_png_from_mem"},
{"imageformats.png.read_png16" : "imageformats/png.html#read_png16"},
{"imageformats.png.read_png16_from_mem" : "imageformats/png.html#read_png16_from_mem"},
{"imageformats.png.write_png" : "imageformats/png.html#write_png"},
{"imageformats.png.write_png_to_mem" : "imageformats/png.html#write_png_to_mem"},
{"imageformats.png.read_png_info" : "imageformats/png.html#read_png_info"},
{"imageformats.png.read_png_info_from_mem" : "imageformats/png.html#read_png_info_from_mem"},
{"imageformats.jpeg" : "imageformats/jpeg.html"},
{"imageformats.jpeg.read_jpeg" : "imageformats/jpeg.html#read_jpeg"},
{"imageformats.jpeg.read_jpeg_from_mem" : "imageformats/jpeg.html#read_jpeg_from_mem"},
{"imageformats.jpeg.read_jpeg_info" : "imageformats/jpeg.html#read_jpeg_info"},
{"imageformats.jpeg.read_jpeg_info_from_mem" : "imageformats/jpeg.html#read_jpeg_info_from_mem"},
{"imageformats.tga" : "imageformats/tga.html"},
{"imageformats.tga.TGA_Header" : "imageformats/tga/TGA_Header.html"},
{"imageformats.tga.read_tga_header" : "imageformats/tga.html#read_tga_header"},
{"imageformats.tga.read_tga_header_from_mem" : "imageformats/tga.html#read_tga_header_from_mem"},
{"imageformats.tga.read_tga" : "imageformats/tga.html#read_tga"},
{"imageformats.tga.read_tga_from_mem" : "imageformats/tga.html#read_tga_from_mem"},
{"imageformats.tga.write_tga" : "imageformats/tga.html#write_tga"},
{"imageformats.tga.write_tga_to_mem" : "imageformats/tga.html#write_tga_to_mem"},
{"imageformats.tga.read_tga_info" : "imageformats/tga.html#read_tga_info"},
{"imageformats.tga.read_tga_info_from_mem" : "imageformats/tga.html#read_tga_info_from_mem"},
{"imageformats.bmp" : "imageformats/bmp.html"},
{"imageformats.bmp.read_bmp" : "imageformats/bmp.html#read_bmp"},
{"imageformats.bmp.read_bmp_from_mem" : "imageformats/bmp.html#read_bmp_from_mem"},
{"imageformats.bmp.read_bmp_header" : "imageformats/bmp.html#read_bmp_header"},
{"imageformats.bmp.read_bmp_header_from_mem" : "imageformats/bmp.html#read_bmp_header_from_mem"},
{"imageformats.bmp.BMP_Header" : "imageformats/bmp/BMP_Header.html"},
{"imageformats.bmp.DibV1" : "imageformats/bmp/DibV1.html"},
{"imageformats.bmp.DibV2" : "imageformats/bmp/DibV2.html"},
{"imageformats.bmp.DibV4" : "imageformats/bmp/DibV4.html"},
{"imageformats.bmp.DibV5" : "imageformats/bmp/DibV5.html"},
{"imageformats.bmp.read_bmp_info" : "imageformats/bmp.html#read_bmp_info"},
{"imageformats.bmp.read_bmp_info_from_mem" : "imageformats/bmp.html#read_bmp_info_from_mem"},
{"imageformats.bmp.write_bmp" : "imageformats/bmp.html#write_bmp"},
{"imageformats.bmp.write_bmp_to_mem" : "imageformats/bmp.html#write_bmp_to_mem"},
{"imageformats" : "imageformats.html"},
{"imageformats.IFImage" : "imageformats/IFImage.html"},
{"imageformats.IFImage.w" : "imageformats/IFImage.html#w"},
{"imageformats.IFImage.h" : "imageformats/IFImage.html#h"},
{"imageformats.IFImage.c" : "imageformats/IFImage.html#c"},
{"imageformats.IFImage.pixels" : "imageformats/IFImage.html#pixels"},
{"imageformats.IFImage16" : "imageformats/IFImage16.html"},
{"imageformats.IFImage16.w" : "imageformats/IFImage16.html#w"},
{"imageformats.IFImage16.h" : "imageformats/IFImage16.html#h"},
{"imageformats.IFImage16.c" : "imageformats/IFImage16.html#c"},
{"imageformats.IFImage16.pixels" : "imageformats/IFImage16.html#pixels"},
{"imageformats.ColFmt" : "imageformats/ColFmt.html"},
{"imageformats.read_image" : "imageformats.html#read_image"},
{"imageformats.read_image_from_mem" : "imageformats.html#read_image_from_mem"},
{"imageformats.write_image" : "imageformats.html#write_image"},
{"imageformats.read_image_info" : "imageformats.html#read_image_info"},
{"imageformats.ImageIOException" : "imageformats/ImageIOException.html"},
];
function search(str) {
	var re = new RegExp(str.toLowerCase());
	var ret = {};
	for (var i = 0; i < items.length; i++) {
		var k = Object.keys(items[i])[0];
		if (re.test(k.toLowerCase()))
			ret[k] = items[i][k];
	}
	return ret;
}

function searchSubmit(value, event) {
	console.log("searchSubmit");
	var resultTable = document.getElementById("results");
	while (resultTable.firstChild)
		resultTable.removeChild(resultTable.firstChild);
	if (value === "" || event.keyCode == 27) {
		resultTable.style.display = "none";
		return;
	}
	resultTable.style.display = "block";
	var results = search(value);
	var keys = Object.keys(results);
	if (keys.length === 0) {
		var row = resultTable.insertRow();
		var td = document.createElement("td");
		var node = document.createTextNode("No results");
		td.appendChild(node);
		row.appendChild(td);
		return;
	}
	for (var i = 0; i < keys.length; i++) {
		var k = keys[i];
		var v = results[keys[i]];
		var link = document.createElement("a");
		link.href = v;
		link.textContent = k;
		link.attributes.id = "link" + i;
		var row = resultTable.insertRow();
		row.appendChild(link);
	}
}

function hideSearchResults(event) {
	if (event.keyCode != 27)
		return;
	var resultTable = document.getElementById("results");
	while (resultTable.firstChild)
		resultTable.removeChild(resultTable.firstChild);
	resultTable.style.display = "none";
}

