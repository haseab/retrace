# Storage Module

**Owner**: STORAGE Agent
**Instructions**: See [CLAUDE-STORAGE.md](../CLAUDE-STORAGE.md)

## Responsibility

File storage and encryption including:
- Video segment creation (HEVC encoding via VideoToolbox)
- File encryption/decryption (CryptoKit AES-256-GCM)
- Keychain key management
- Disk space monitoring and cleanup

## Files to Create

```
Storage/
├── StorageManager.swift
├── SegmentWriterImpl.swift
├── Encryption/
│   ├── EncryptionManager.swift
│   └── KeychainHelper.swift
├── FileManager/
│   ├── DirectoryManager.swift
│   └── StorageHealthMonitor.swift
├── VideoEncoder/
│   ├── HEVCEncoder.swift
│   └── FrameConverter.swift
└── Tests/
    ├── StorageManagerTests.swift
    ├── EncryptionTests.swift
    └── HEVCEncoderTests.swift
```

## Protocols to Implement

- `StorageProtocol` (from `Shared/Protocols/StorageProtocol.swift`)
- `SegmentWriter` (from `Shared/Protocols/StorageProtocol.swift`)
