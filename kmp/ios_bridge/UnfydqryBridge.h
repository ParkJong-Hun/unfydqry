// AUTO-GENERATED — do not edit by hand.
// Re-generate with: ./kmp/scripts/generate_bridge_header.sh
//
// This header exposes the @objc declarations from UnfydqryBridge.swift
// so that Kotlin/Native's cinterop tool can generate bindings without
// an Xcode build step.  You maintain only UnfydqryBridge.swift; run the
// script to keep this file in sync.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface UnfydqryHit : NSObject
@property (nonatomic, readonly) int64_t hitId;
@property (nonatomic, readonly) double score;
@end

@interface UnfydqrySearchEngine : NSObject
+ (nullable UnfydqrySearchEngine *)createWithDbPath:(NSString *)dbPath
                                              error:(NSError *_Nullable *_Nullable)error;
- (BOOL)indexWithId:(int64_t)itemId text:(NSString *)text
              error:(NSError *_Nullable *_Nullable)error;
- (BOOL)removeWithId:(int64_t)itemId
               error:(NSError *_Nullable *_Nullable)error;
- (nullable NSArray<UnfydqryHit *> *)searchWithQuery:(NSString *)query
                                               limit:(int32_t)limit
                                               error:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
