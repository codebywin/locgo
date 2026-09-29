#import <Foundation/Foundation.h>

@interface ZipManager : NSObject

+ (BOOL)createZipArchiveAtPath:(NSString *)destinationZipPath
              fromSourceFolder:(NSString *)sourceFolderPath
                         error:(NSError **)error;

@end
