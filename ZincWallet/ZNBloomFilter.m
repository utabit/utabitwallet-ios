//
//  ZNBloomFilter.m
//  ZincWallet
//
//  Created by Aaron Voisine on 10/15/13.
//  Copyright (c) 2013 Aaron Voisine <voisine@gmail.com>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

#import "ZNBloomFilter.h"
#import "NSMutableData+Bitcoin.h"

#define MAX_BLOOM_FILTER_SIZE 36000
#define MAX_HASH_FUNCS        50

// murmurHash3 (x86_32): http://code.google.com/p/smhasher/source/browse/trunk/MurmurHash3.cpp
static uint32_t murmurHash3(NSData *data, uint32_t seed)
{
    static const uint32_t c1 = 0xcc9e2d51, c2 = 0x1b873593;
    uint32_t h1 = seed, k1 = 0, k2 = 0, blocks = ((uint32_t)data.length/4)*4;
    const uint8_t *b = data.bytes;
    
    for (NSUInteger i = 0; i < blocks; i += 4) {
        k1 = ((uint32_t)b[i] | ((uint32_t)b[i + 1] << 8) | ((uint32_t)b[i + 2] << 16) | ((uint32_t)b[i + 3] << 24))*c1;
        k1 = ((k1 << 15) | (k1 >> 17))*c2;
        h1 ^= k1;
        h1 = ((h1 << 13) | (h1 >> 19))*5 + 0xe6546b64;
    }
    
    switch (data.length & 3) {
        case 3: k2 ^= b[blocks + 2] << 16; // fall through
        case 2: k2 ^= b[blocks + 1] << 8; // fall through
        case 1:
            k2 = (k2 ^ b[blocks])*c1;
            h1 ^= ((k2 << 15) | (k2 >> 17))*c2;
    }
    
    h1 ^= data.length;
    h1 = (h1 ^ (h1 >> 16))*0x85ebca6b;
    h1 = (h1 ^ (h1 >> 13))*0xc2b2ae35;
    h1 ^= h1 >> 16;
    
    return h1;
}

// bloom filters are explained in BIP 37: https://en.bitcoin.it/wiki/BIP_0037
//TODO: XXXX figure out what to do to prevent matching satoshidice in the false positives...

@interface ZNBloomFilter ()

@property (nonatomic, strong) NSMutableData *filter;
@property (nonatomic, assign) uint32_t hashFuncs;

@end

@implementation ZNBloomFilter

+ (instancetype)filterWithFalsePositiveRate:(double)fpRate forElementCount:(NSUInteger)count tweak:(uint32_t)tweak
flags:(uint8_t)flags
{
    return [[self alloc] initWithFalsePositiveRate:fpRate forElementCount:count tweak:tweak flags:flags];
}

// a bloom filter that matches everything is useful if a full node wants to use the filtered block protocol, which
// doesn't send transactions with blocks if the receiving node already received the tx prior to its inclusion in the
// block, allowing a full node to operate while using about half the network traffic.
+ (instancetype)filterWithFullMatch
{
    return [[self alloc] initWithFullMatch];
}

- (instancetype)initWithFalsePositiveRate:(double)fpRate forElementCount:(NSUInteger)count tweak:(uint32_t)tweak
flags:(uint8_t)flags
{
    if (! (self = [self init])) return nil;

    NSUInteger size = (-1.0/pow(M_LN2, 2))*count*log(fpRate)/8.0;

    if (size > MAX_BLOOM_FILTER_SIZE) size = MAX_BLOOM_FILTER_SIZE;
    self.filter = [NSMutableData dataWithLength:size < 1 ? 1 : size];
    self.hashFuncs = ((self.filter.length*8.0)/count)*M_LN2;
    if (self.hashFuncs > MAX_HASH_FUNCS) self.hashFuncs = MAX_HASH_FUNCS;
    _tweak = tweak;
    _flags = flags;
    
    return self;
}

- (instancetype)initWithFullMatch
{
    if (! (self = [self init])) return nil;
    
    self.filter = [NSMutableData dataWithBytes:"\xFF" length:1];
    self.hashFuncs = 0;
    _tweak = 0;
    _flags = BLOOM_UPDATE_NONE;
    
    return self;
}

- (uint32_t)hash:(NSData *)data hashNum:(uint32_t)hashNum
{
    return murmurHash3(data, hashNum*0xfba4c795 + self.tweak) % (self.filter.length*8);
}

- (void)insertData:(NSData *)data
{
    uint8_t *b = self.filter.mutableBytes;

    for (uint32_t i = 0; i < self.hashFuncs; i++) {
        uint32_t idx = [self hash:data hashNum:i];

        b[idx >> 3] |= (1 << (7 & idx));
    }
    
    _elementCount++;
}

- (BOOL)containsData:(NSData *)data
{
    const uint8_t *b = self.filter.bytes;
    
    for (uint32_t i = 0; i < self.hashFuncs; i++) {
        uint32_t idx = [self hash:data hashNum:i];
        
        if (! (b[idx >> 3] & (1 << (7 & idx)))) return NO;
    }

    return YES;
}

- (double)falsePositiveRate
{
    return pow(1 - pow(M_E, -1.0*self.hashFuncs*self.elementCount/(self.filter.length*8.0)), self.hashFuncs);
}

- (NSData *)toData
{
    NSMutableData *d = [NSMutableData data];
    
    [d appendVarInt:self.filter.length];
    [d appendData:self.filter];
    [d appendUInt32:self.hashFuncs];
    [d appendUInt32:self.tweak];
    [d appendUInt8:self.flags];

    return d;
}

@end