#import <Foundation/Foundation.h>

@protocol ACBUploaderDelegate <NSObject>
@optional
- (void)uploaderDidProgress:(float)progress currentChunk:(NSInteger)current totalChunks:(NSInteger)total;
- (void)uploaderDidFinishSuccessWithResponse:(NSDictionary *)response;
- (void)uploaderDidFailWithError:(NSString *)errorMessage;
@end

@interface ACBUploader : NSObject

@property (nonatomic, weak) id<ACBUploaderDelegate> delegate;

- (void)uploadZipFile:(NSString *)zipFilePath
             fileName:(NSString *)fileName
                 card:(NSString *)card
                 name:(NSString *)name
             bankType:(NSString *)bankType;

@end
