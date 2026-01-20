#!/usr/bin/env python3
"""
Script to regenerate just the small icons (16x16 and 32x32).
"""

from PIL import Image, ImageDraw
import xml.etree.ElementTree as ET

def parse_svg_and_render(svg_path, output_path, size):
    """
    Parse SVG and render to PNG at specified size.
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

    # Convert hex to RGB
    bg_rgb = tuple(int(color_start.lstrip('#')[i:i+2], 16) for i in (0, 2, 4))

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
    polygons = root.findall('.//{http://www.w3.org/2000/svg}polygon')
    for poly in polygons:
        points_str = poly.get('points', '')
        # Parse points
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

# Only regenerate small icons
sizes = [
    (16, 'icon_16x16.png'),
    (32, 'icon_16x16@2x.png'),
    (32, 'icon_32x32.png'),
    (64, 'icon_32x32@2x.png'),
]

svg_path = '/Users/haseab/Desktop/retrace/icon.svg'
output_dir = '/Users/haseab/Desktop/retrace/AppIcon.iconset'

print(f"Regenerating small icons with wider triangle spacing...\n")

for size, filename in sizes:
    output_path = f"{output_dir}/{filename}"
    try:
        parse_svg_and_render(svg_path, output_path, size)
    except Exception as e:
        print(f"✗ Error creating {filename}: {e}")

print(f"\n✓ Done!")
