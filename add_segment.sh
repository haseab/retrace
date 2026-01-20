#!/bin/bash

# Backup project file
cp Retrace.xcodeproj/project.pbxproj Retrace.xcodeproj/project.pbxproj.backup2

# Generate unique IDs for Segment.swift (using a consistent hash pattern like the project uses)
SEGMENT_FILE_REF="BC72AEB82A99D387275B9380"  # Unique ID for file reference
SEGMENT_BUILD_FILE="5E7B587B56D029A567BEEF01" # Unique ID for build file

# 1. Add PBXBuildFile entry (around line 70 after Frame.swift)
sed -i '' "70 a\\
\\		${SEGMENT_BUILD_FILE} /* Segment.swift in Sources */ = {isa = PBXBuildFile; fileRef = ${SEGMENT_FILE_REF} /* Segment.swift */; };\\
" Retrace.xcodeproj/project.pbxproj

# 2. Add PBXFileReference entry (around line 434 after Frame.swift)
sed -i '' "435 a\\
\\		${SEGMENT_FILE_REF} /* Segment.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Segment.swift; sourceTree = \"<group>\"; };\\
" Retrace.xcodeproj/project.pbxproj

# 3. Add to Models group (around line 910 after Frame.swift) 
sed -i '' "911 a\\
\\				${SEGMENT_FILE_REF} /* Segment.swift */,\\
" Retrace.xcodeproj/project.pbxproj

# 4. Add to Sources build phase (around line 1308)
sed -i '' "1309 a\\
\\				${SEGMENT_BUILD_FILE} /* Segment.swift in Sources */,\\
" Retrace.xcodeproj/project.pbxproj

echo "Added Segment.swift to Xcode project"
