#!/usr/bin/env python3
"""
Script to restore white color to the triangles in the icons.
This finds transparent/semi-transparent pixels within the blue rounded square
and makes them white.
"""

from PIL import Image, ImageDraw
import os
from pathlib import Path

def restore_white_triangles(image_path):
    """
    Restore white color to the triangle shapes.
    Strategy: Find pixels that are transparent but should be white (within the icon bounds),
    and make them white again.

    Args:
        image_path: Path to the image file
    """
    # Open the image
    img = Image.open(image_path).convert("RGBA")
    width, height = img.size

    # Get pixel data
    pixels = img.load()

    # Iterate through all pixels
    for y in range(height):
        for x in range(width):
            r, g, b, a = pixels[x, y]

            # If pixel is transparent or semi-transparent but was likely white
            # (high RGB values but low alpha)
            if a < 255 and r >= 200 and g >= 200 and b >= 200:
                # Check if it's not on the outer edges (not part of background)
                # Heuristic: if surrounded by non-transparent or blue pixels, it's a triangle
                is_inside = False

                # Check neighboring pixels for blue color (the icon background)
                for dy in [-1, 0, 1]:
                    for dx in [-1, 0, 1]:
                        if dx == 0 and dy == 0:
                            continue
                        ny, nx = y + dy, x + dx
                        if 0 <= ny < height and 0 <= nx < width:
                            nr, ng, nb, na = pixels[nx, ny]
                            # Check if neighbor is blue (icon background color)
                            if na > 200 and nb > 100 and nr < 100 and ng < 100:
                                is_inside = True
                                break
                    if is_inside:
                        break

                # If inside the icon, make it white
                if is_inside:
                    pixels[x, y] = (255, 255, 255, 255)

    # Save the image
    img.save(image_path, "PNG")
    print(f"✓ Fixed: {image_path.name}")

def process_icons_directory(directory):
    """Process all PNG files in a directory."""
    path = Path(directory)
    if not path.exists():
        print(f"✗ Directory not found: {directory}")
        return 0

    png_files = sorted(path.glob("*.png"))
    print(f"\nFixing {len(png_files)} PNG files in {path.name}/")

    processed = 0
    for png_file in png_files:
        try:
            restore_white_triangles(png_file)
            processed += 1
        except Exception as e:
            print(f"✗ Error processing {png_file.name}: {e}")

    return processed

if __name__ == "__main__":
    # Process both icon directories
    directories = [
        "/Users/haseab/Desktop/retrace/AppIcon.iconset",
        "/Users/haseab/Desktop/retrace/UI/Assets.xcassets/AppIcon.appiconset"
    ]

    total_processed = 0
    for directory in directories:
        total_processed += process_icons_directory(directory)

    print(f"\n✓ Done! Fixed {total_processed} icons total.")
