#!/bin/bash

# Backup project file
cp Retrace.xcodeproj/project.pbxproj Retrace.xcodeproj/project.pbxproj.backup3

# Generate unique IDs for AppSegmentQueries.swift
APPSEG_FILE_REF="AED7B265E8C17B90845559FE"  # New unique ID for file reference
APPSEG_BUILD_FILE="882363BB628B0C22224ADEFE" # New unique ID for build file

# Find the line numbers for DocumentQueries.swift to insert after it
DOC_QUERIES_BUILD_LINE=$(grep -n "DocumentQueries.swift in Sources" Retrace.xcodeproj/project.pbxproj | head -1 | cut -d: -f1)
DOC_QUERIES_REF_LINE=$(grep -n "DocumentQueries.swift */ =" Retrace.xcodeproj/project.pbxproj | grep PBXFileReference | head -1 | cut -d: -f1)
DOC_QUERIES_GROUP_LINE=$(grep -n "DocumentQueries.swift */," Retrace.xcodeproj/project.pbxproj | grep -v "in Sources" | head -1 | cut -d: -f1)
DOC_QUERIES_SOURCE_LINE=$(grep -n "DocumentQueries.swift in Sources */," Retrace.xcodeproj/project.pbxproj | head -1 | cut -d: -f1)

# 1. Add PBXBuildFile entry (after DocumentQueries build file)
sed -i '' "${DOC_QUERIES_BUILD_LINE} a\\
\\		${APPSEG_BUILD_FILE} /* AppSegmentQueries.swift in Sources */ = {isa = PBXBuildFile; fileRef = ${APPSEG_FILE_REF} /* AppSegmentQueries.swift */; };\\
" Retrace.xcodeproj/project.pbxproj

# 2. Add PBXFileReference entry (after DocumentQueries file ref)
sed -i '' "${DOC_QUERIES_REF_LINE} a\\
\\		${APPSEG_FILE_REF} /* AppSegmentQueries.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AppSegmentQueries.swift; sourceTree = \"<group>\"; };\\
" Retrace.xcodeproj/project.pbxproj

# 3. Add to Queries group (after DocumentQueries in group)
sed -i '' "${DOC_QUERIES_GROUP_LINE} a\\
\\				${APPSEG_FILE_REF} /* AppSegmentQueries.swift */,\\
" Retrace.xcodeproj/project.pbxproj

# 4. Add to Database Sources build phase (after DocumentQueries in sources)
sed -i '' "${DOC_QUERIES_SOURCE_LINE} a\\
\\				${APPSEG_BUILD_FILE} /* AppSegmentQueries.swift in Sources */,\\
" Retrace.xcodeproj/project.pbxproj

echo "Added AppSegmentQueries.swift to Xcode project"
