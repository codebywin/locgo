#import "ZipManager.h"
#import <zlib.h>

#pragma pack(push, 1)
typedef struct {
    uint32_t signature; // 0x04034b50
    uint16_t versionNeeded;
    uint16_t generalFlags;
    uint16_t compressionMethod;
    uint16_t lastModTime;
    uint16_t lastModDate;
    uint32_t crc32;
    uint32_t compressedSize;
    uint32_t uncompressedSize;
    uint16_t fileNameLength;
    uint16_t extraFieldLength;
} ZipLocalHeader;

typedef struct {
    uint32_t signature; // 0x02014b50
    uint16_t versionMadeBy;
    uint16_t versionNeeded;
    uint16_t generalFlags;
    uint16_t compressionMethod;
    uint16_t lastModTime;
    uint16_t lastModDate;
    uint32_t crc32;
    uint32_t compressedSize;
    uint32_t uncompressedSize;
    uint16_t fileNameLength;
    uint16_t extraFieldLength;
    uint16_t fileCommentLength;
    uint16_t diskNumberStart;
    uint16_t internalFileAttr;
    uint32_t externalFileAttr;
    uint32_t relativeOffsetOfLocalHeader;
} ZipCentralHeader;

typedef struct {
    uint32_t signature; // 0x06054b50
    uint16_t diskNumber;
    uint16_t diskWithCentralDir;
    uint16_t totalEntriesThisDisk;
    uint16_t totalEntries;
    uint32_t sizeOfCentralDir;
    uint32_t offsetOfCentralDir;
    uint16_t commentLength;
} ZipEndOfCentralDir;
#pragma pack(pop)

@implementation ZipManager

+ (BOOL)createZipArchiveAtPath:(NSString *)destinationZipPath
              fromSourceFolder:(NSString *)sourceFolderPath
                         error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:sourceFolderPath]) {
        return NO;
    }
    
    // Tao file zip moi
    NSMutableData *zipData = [NSMutableData data];
    NSMutableData *centralDirData = [NSMutableData data];
    
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:sourceFolderPath];
    NSString *relativePath;
    uint16_t entryCount = 0;
    
    while ((relativePath = [enumerator nextObject])) {
        NSString *fullPath = [sourceFolderPath stringByAppendingPathComponent:relativePath];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:fullPath isDirectory:&isDir] && !isDir) {
            // Chi dong goi file, khong dong goi thu muc rong
            NSData *fileData = [NSData dataWithContentsOfFile:fullPath];
            if (!fileData) continue;
            
            // Chuyen path separator thanh '/' chuan zip
            NSString *entryName = [relativePath stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
            NSData *entryNameData = [entryName dataUsingEncoding:NSUTF8StringEncoding];
            
            uint32_t fileCrc = (uint32_t)crc32(0, (const Bytef *)fileData.bytes, (uInt)fileData.length);
            uint32_t localHeaderOffset = (uint32_t)zipData.length;
            
            // Local Header (Compression Method 0 = Store de toc do nhanh va khong ton CPU voi anh JPG)
            ZipLocalHeader localHeader;
            memset(&localHeader, 0, sizeof(localHeader));
            localHeader.signature = 0x04034b50;
            localHeader.versionNeeded = 20;
            localHeader.compressionMethod = 0; // Store (anh JPG da nen san)
            localHeader.crc32 = fileCrc;
            localHeader.compressedSize = (uint32_t)fileData.length;
            localHeader.uncompressedSize = (uint32_t)fileData.length;
            localHeader.fileNameLength = (uint16_t)entryNameData.length;
            
            [zipData appendBytes:&localHeader length:sizeof(localHeader)];
            [zipData appendData:entryNameData];
            [zipData appendData:fileData];
            
            // Central Directory Header
            ZipCentralHeader centralHeader;
            memset(&centralHeader, 0, sizeof(centralHeader));
            centralHeader.signature = 0x02014b50;
            centralHeader.versionMadeBy = 20;
            centralHeader.versionNeeded = 20;
            centralHeader.compressionMethod = 0;
            centralHeader.crc32 = fileCrc;
            centralHeader.compressedSize = (uint32_t)fileData.length;
            centralHeader.uncompressedSize = (uint32_t)fileData.length;
            centralHeader.fileNameLength = (uint16_t)entryNameData.length;
            centralHeader.relativeOffsetOfLocalHeader = localHeaderOffset;
            
            [centralDirData appendBytes:&centralHeader length:sizeof(centralHeader)];
            [centralDirData appendData:entryNameData];
            
            entryCount++;
        }
    }
    
    // Ghi Central Directory vao cuoi zip
    uint32_t centralDirOffset = (uint32_t)zipData.length;
    uint32_t centralDirSize = (uint32_t)centralDirData.length;
    [zipData appendData:centralDirData];
    
    // Ghi End of Central Directory
    ZipEndOfCentralDir endRecord;
    memset(&endRecord, 0, sizeof(endRecord));
    endRecord.signature = 0x06054b50;
    endRecord.totalEntriesThisDisk = entryCount;
    endRecord.totalEntries = entryCount;
    endRecord.sizeOfCentralDir = centralDirSize;
    endRecord.offsetOfCentralDir = centralDirOffset;
    
    [zipData appendBytes:&endRecord length:sizeof(endRecord)];
    
    return [zipData writeToFile:destinationZipPath atomically:YES];
}

+ (BOOL)zipDirectory:(NSString *)dir toPath:(NSString *)zipPath {
    return [self createZipArchiveAtPath:zipPath fromSourceFolder:dir error:nil];
}

@end
