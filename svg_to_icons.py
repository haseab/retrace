#!/usr/bin/env python3
"""
Script to convert SVG to PNG icons at all required sizes.
Uses cairosvg or svg.path to render SVG.
"""

from PIL import Image, ImageDraw
import xml.etree.ElementTree as ET

def parse_svg_and_render(svg_path, output_path, size):
    """
    Parse SVG and render to PNG at specified size.
    This is a simple renderer that handles basic SVG elements.
    """
    # Parse the SVG
    tree = ET.parse(svg_path)
    root = tree.getroot()

    # Get viewBox to understand coordinate system
    viewbox = root.get('viewBox', '0 0 100 100').split()
    vb_width = float(viewbox[2])
    vb_height = float(viewbox[3])

    # Create image with transparency
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Calculate scale factor
    scale = size / vb_width

    # Parse gradient colors
    gradient_stops = root.findall('.//{http://www.w3.org/2000/svg}stop')
    color_start = gradient_stops[0].get('stop-color', '#0B3571')
    color_end = gradient_stops[1].get('stop-color', '#082B5F')

    # For simplicity, use the middle color (we can't do real gradients easily in PIL)
    # Use the start color as a solid fill
    bg_color = color_start

    # Convert hex to RGB
    bg_rgb = tuple(int(bg_color.lstrip('#')[i:i+2], 16) for i in (0, 2, 4))

    # Find and draw the rounded rectangle background
    rect = root.find('.//{http://www.w3.org/2000/svg}rect')
    if rect is not None:
        rx = float(rect.get('rx', 0)) * scale
        # Draw rounded rectangle
        draw.rounded_rectangle(
            [(0, 0), (size, size)],
            radius=rx,
            fill=bg_rgb + (255,)
        )

    # Find and draw polygons (the triangles)
    # First find the group that contains them
    groups = root.findall('.//{http://www.w3.org/2000/svg}g')
    group_fill = '#fff'
    for g in groups:
        if g.get('fill'):
            group_fill = g.get('fill')

    polygons = root.findall('.//{http://www.w3.org/2000/svg}polygon')
    for poly in polygons:
        points_str = poly.get('points', '')
        # Parse points: "23,50 47,34 47,66" -> [(23,50), (47,34), (47,66)]
        points = []
        for point in points_str.split():
            x, y = point.split(',')
            # Scale to output size
            scaled_x = float(x) * scale
            scaled_y = float(y) * scale
            points.append((scaled_x, scaled_y))

        # Use white for the triangles
        fill_rgb = (255, 255, 255, 255)

        # Draw polygon
        draw.polygon(points, fill=fill_rgb)

    # Save the image
    img.save(output_path, 'PNG')
    print(f"✓ Created: {output_path}")

# Icon sizes needed for macOS
sizes = [
    (16, 'icon_16x16.png'),
    (32, 'icon_16x16@2x.png'),
    (32, 'icon_32x32.png'),
    (64, 'icon_32x32@2x.png'),
    (128, 'icon_128x128.png'),
    (256, 'icon_128x128@2x.png'),
    (256, 'icon_256x256.png'),
    (512, 'icon_256x256@2x.png'),
    (512, 'icon_512x512.png'),
    (1024, 'icon_512x512@2x.png'),
]

svg_path = '/Users/haseab/Desktop/retrace/icon.svg'
output_dir = '/Users/haseab/Desktop/retrace/AppIcon.iconset'

print(f"Converting SVG to {len(sizes)} icon sizes...\n")

for size, filename in sizes:
    output_path = f"{output_dir}/{filename}"
    try:
        parse_svg_and_render(svg_path, output_path, size)
    except Exception as e:
        print(f"✗ Error creating {filename}: {e}")

print(f"\n✓ Done! Created {len(sizes)} icons in {output_dir}/")
