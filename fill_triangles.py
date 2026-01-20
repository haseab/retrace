#!/usr/bin/env python3
"""
Script to fill the triangle shapes with solid white color.
"""

from PIL import Image, ImageDraw

def fill_triangles_with_white(image_path):
    """
    Fill the transparent triangle areas with white.

    Args:
        image_path: Path to the image file
    """
    # Open the image
    img = Image.open(image_path).convert("RGBA")
    width, height = img.size

    # Create a new image to draw on
    draw = ImageDraw.Draw(img)

    # Find the center of the image
    center_x, center_y = width // 2, height // 2

    # Define the two triangles (left and right pointing)
    # These are approximate coordinates - we'll draw filled triangles

    # Left-pointing triangle (approximately)
    # Triangle points: top-left corner, center-left, bottom-left corner
    left_triangle = [
        (center_x * 0.23, center_y),  # Left point
        (center_x * 0.77, center_y * 0.34),  # Top-right point
        (center_x * 0.77, center_y * 1.66)   # Bottom-right point
    ]

    # Right-pointing triangle
    right_triangle = [
        (center_x * 1.77, center_y),  # Right point
        (center_x * 1.23, center_y * 0.34),  # Top-left point
        (center_x * 1.23, center_y * 1.66)   # Bottom-left point
    ]

    # Fill triangles with white
    draw.polygon(left_triangle, fill=(255, 255, 255, 255))
    draw.polygon(right_triangle, fill=(255, 255, 255, 255))

    # Save the image
    img.save(image_path, "PNG")
    print(f"✓ Filled triangles in: {image_path}")

if __name__ == "__main__":
    # Test on one icon first
    test_icon = "/Users/haseab/Desktop/retrace/AppIcon.iconset/icon_512x512.png"
    fill_triangles_with_white(test_icon)
    print(f"\nDone! Check the result: {test_icon}")
