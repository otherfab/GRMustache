// The MIT License
// 
// Copyright (c) 2012 Gwendal Roué
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "GRMustacheParser_private.h"
#import "GRMustacheError.h"

@interface GRMustacheParser()

/**
 * The Mustache tag opening delimiter. Initialized with @"{{", it may change
 * with "change delimiter" tags such as `{{=< >=}}`.
 */
@property (nonatomic, copy) NSString *otag;

/**
 * The Mustache tag opening delimiter. Initialized with @"}}", it may change
 * with "change delimiter" tags such as `{{=< >=}}`.
 */
@property (nonatomic, copy) NSString *ctag;

/**
 * Wrapper around the delegate's `parser:shouldContinueAfterParsingToken:`
 * method.
 */
- (BOOL)shouldContinueAfterParsingToken:(GRMustacheToken *)token;

/**
 * Wrapper around the delegate's `parser:didFailWithError:` method.
 * 
 * @param line          The line at which the error occurred.
 * @param description   A human-readable error message
 * @param templateID    A template ID (see GRMustacheTemplateRepository)
 */
- (void)failWithParseErrorAtLine:(NSInteger)line description:(NSString *)description templateID:(id)templateID;

/**
 * String lookup method.
 * 
 * @param needle    The string to look for.
 * @param haystack  The string to look into.
 * @param p         The index from which the search should begin
 * @param outLines  A pointer to an integer. Upon return contains the number of
 *                  '\n' characters between _p_ and the location of the returned
 *                  range.
 *
 * @return  The range of needle in haystack. If the location of range is
 *          NSNotFound, the needle was not found in the haystack.
 */
- (NSRange)rangeOfString:(NSString *)needle inTemplateString:(NSString *)haystack startingAtIndex:(NSUInteger)p consumedNewLines:(NSUInteger *)outLines;

/**
 * Returns an array of keys from the inner string of a tag.
 *
 * @param innerTagString  the inner string of a tag.
 *
 * @return an Array of keys, or nil if the parsing fails.
 */
- (NSArray *)parseKeyPath:(NSString *)innerTagString;

/**
 * Returns a partial name from the inner string of a tag.
 *
 * @param innerTagString  the inner string of a tag.
 *
 * @return a partial name, or nil if the string is not an identifier.
 */
- (NSString *)parsePartialName:(NSString *)innerTagString;
@end

@implementation GRMustacheParser
@synthesize delegate=_delegate;
@synthesize otag=_otag;
@synthesize ctag=_ctag;

- (id)init
{
    self = [super init];
    if (self) {
        _otag = [@"{{" retain]; // static strings don't need retain, but static ananlyser may complain :-)
        _ctag = [@"}}" retain];
    }
    return self;
}

- (void)dealloc
{
    [_otag release];
    [_ctag release];
    [super dealloc];
}

- (void)parseTemplateString:(NSString *)templateString templateID:(id)templateID
{
    NSUInteger p = 0;
    NSUInteger line = 1;
    NSUInteger consumedLines = 0;
    NSRange orange;
    NSRange crange;
    NSString *tag;
    unichar character;
    NSCharacterSet *whitespaceCharacterSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    GRMustacheTokenType tokenType;
    NSRange tokenRange;
    static const GRMustacheTokenType tokenTypeForCharacter[] = {    // tokenTypeForCharacter[unspecified character] = 0 = GRMustacheTokenTypeEscapedVariable
        ['!'] = GRMustacheTokenTypeComment,
        ['#'] = GRMustacheTokenTypeSectionOpening,
        ['^'] = GRMustacheTokenTypeInvertedSectionOpening,
        ['/'] = GRMustacheTokenTypeSectionClosing,
        ['>'] = GRMustacheTokenTypePartial,
        ['='] = GRMustacheTokenTypeSetDelimiter,
        ['{'] = GRMustacheTokenTypeUnescapedVariable,
        ['&'] = GRMustacheTokenTypeUnescapedVariable,
    };
    static const int tokenTypeForCharacterLength = sizeof(tokenTypeForCharacter) / sizeof(GRMustacheTokenType);
    
    
    while (YES) {
        // look for otag
        orange = [self rangeOfString:_otag inTemplateString:templateString startingAtIndex:p consumedNewLines:&consumedLines];
        
        // otag was not found
        if (orange.location == NSNotFound) {
            if (p < templateString.length) {
                [self shouldContinueAfterParsingToken:[GRMustacheToken tokenWithType:GRMustacheTokenTypeText
                                                                               value:(GRMustacheTokenValue){ .text = [templateString substringFromIndex:p] }
                                                                      templateString:templateString
                                                                          templateID:templateID
                                                                                line:line
                                                                               range:NSMakeRange(p, templateString.length-p)]];
            }
            return;
        }
        
        if (orange.location > p) {
            NSRange range = NSMakeRange(p, orange.location-p);
            if (![self shouldContinueAfterParsingToken:[GRMustacheToken tokenWithType:GRMustacheTokenTypeText
                                                                                value:(GRMustacheTokenValue){ .text = [templateString substringWithRange:range] }
                                                                       templateString:templateString
                                                                           templateID:templateID
                                                                                 line:line
                                                                                range:range]]) {
                return;
            }
        }
        
        // update our cursors
        p = orange.location + orange.length;
        line += consumedLines;
        
        // look for close tag
        if (p < templateString.length && [templateString characterAtIndex:p] == '{') {
            crange = [self rangeOfString:[@"}" stringByAppendingString:_ctag] inTemplateString:templateString startingAtIndex:p consumedNewLines:&consumedLines];
        } else {
            crange = [self rangeOfString:_ctag inTemplateString:templateString startingAtIndex:p consumedNewLines:&consumedLines];
        }
        
        // ctag was not found
        if (crange.location == NSNotFound) {
            [self failWithParseErrorAtLine:line description:@"Unmatched opening tag" templateID:templateID];
            return;
        }
        
        // extract tag
        tag = [templateString substringWithRange:NSMakeRange(orange.location + orange.length, crange.location - orange.location - orange.length)];
        
        // empty tag is not allowed
        if (tag.length == 0) {
            [self failWithParseErrorAtLine:line description:@"Empty tag" templateID:templateID];
            return;
        }
        
        // tag must not contain otag
        if ([tag rangeOfString:_otag].location != NSNotFound) {
            [self failWithParseErrorAtLine:line description:@"Unmatched opening tag" templateID:templateID];
            return;
        }
        
        // interpret tag
        character = [tag characterAtIndex: 0];
        tokenType = (character < tokenTypeForCharacterLength) ? tokenTypeForCharacter[character] : GRMustacheTokenTypeEscapedVariable;
        tokenRange = NSMakeRange(orange.location, crange.location + crange.length - orange.location);
        GRMustacheToken *token = nil;
        switch (tokenType) {
            case GRMustacheTokenTypeComment:
                token = [GRMustacheToken tokenWithType:GRMustacheTokenTypeComment
                                                 value:(GRMustacheTokenValue){ .text = [tag substringFromIndex:1] }   // strip initial '!'
                                        templateString:templateString
                                            templateID:templateID
                                                  line:line
                                                 range:tokenRange];
                break;
                
            case GRMustacheTokenTypeEscapedVariable: {    // default value in tokenTypeForCharacter = 0 = GRMustacheTokenTypeEscapedVariable
                NSArray *keys = [self parseKeyPath:tag];
                if (!keys) {
                    [self failWithParseErrorAtLine:line description:@"Invalid identifier" templateID:templateID];
                    return;
                }
                token = [GRMustacheToken tokenWithType:GRMustacheTokenTypeEscapedVariable
                                                 value:(GRMustacheTokenValue){ .keys = keys }
                                        templateString:templateString
                                            templateID:templateID
                                                  line:line
                                                 range:tokenRange];
            } break;
                
            case GRMustacheTokenTypeSectionOpening:
            case GRMustacheTokenTypeInvertedSectionOpening:
            case GRMustacheTokenTypeSectionClosing:
            case GRMustacheTokenTypeUnescapedVariable: {
                NSArray *keys = [self parseKeyPath:[tag substringFromIndex:1]];   // strip initial '#', '^' etc.
                if (!keys) {
                    [self failWithParseErrorAtLine:line description:@"Invalid identifier" templateID:templateID];
                    return;
                }
                token = [GRMustacheToken tokenWithType:tokenType
                                                 value:(GRMustacheTokenValue){ .keys = keys }
                                        templateString:templateString
                                            templateID:templateID
                                                  line:line
                                                 range:tokenRange];
            } break;
                
            case GRMustacheTokenTypePartial: {
                NSString *partialName = [self parsePartialName:[tag substringFromIndex:1]];   // strip initial '>'
                if (partialName == nil) {
                    [self failWithParseErrorAtLine:line description:@"Invalid partial name" templateID:templateID];
                    return;
                }
                token = [GRMustacheToken tokenWithType:tokenType
                                                 value:(GRMustacheTokenValue){ .partialName = partialName }
                                        templateString:templateString
                                            templateID:templateID
                                                  line:line
                                                 range:tokenRange];
            } break;
                
            case GRMustacheTokenTypeSetDelimiter:
                if ([tag characterAtIndex:tag.length-1] != '=') {
                    [self failWithParseErrorAtLine:line description:@"Invalid set delimiter tag" templateID:templateID];
                    return;
                }
                NSString *tokenContent = [[tag substringWithRange:NSMakeRange(1, tag.length-2)] stringByTrimmingCharactersInSet:whitespaceCharacterSet];
                NSArray *newTags = [tokenContent componentsSeparatedByCharactersInSet:whitespaceCharacterSet];
                NSMutableArray *nonBlankNewTags = [NSMutableArray array];
                for (NSString *newTag in newTags) {
                    if (newTag.length > 0) {
                        [nonBlankNewTags addObject:newTag];
                    }
                }
                if (nonBlankNewTags.count == 2) {
                    self.otag = [nonBlankNewTags objectAtIndex:0];
                    self.ctag = [nonBlankNewTags objectAtIndex:1];
                } else {
                    [self failWithParseErrorAtLine:line description:@"Invalid set delimiter tag" templateID:templateID];
                    return;
                }
                token = [GRMustacheToken tokenWithType:GRMustacheTokenTypeSetDelimiter
                                                 value:(GRMustacheTokenValue){ .object = nil }
                                        templateString:templateString
                                            templateID:templateID
                                                  line:line
                                                 range:tokenRange];
                break;
                
            case GRMustacheTokenTypeText:
                NSAssert(NO, @"");
                break;
        }

        NSAssert(token, @"WTF");
        if (![self shouldContinueAfterParsingToken:token]) {
            return;
        }

        // update our cursors
        p = crange.location + crange.length;
        line += consumedLines;
    }
}

#pragma mark Private

- (BOOL)shouldContinueAfterParsingToken:(GRMustacheToken *)token
{
    if ([_delegate respondsToSelector:@selector(parser:shouldContinueAfterParsingToken:)]) {
        return [_delegate parser:self shouldContinueAfterParsingToken:token];
    }
    return YES;
}

- (void)failWithParseErrorAtLine:(NSInteger)line description:(NSString *)description templateID:(id)templateID
{
    if ([_delegate respondsToSelector:@selector(parser:didFailWithError:)]) {
        NSString *localizedDescription;
        if (templateID) {
            localizedDescription = [NSString stringWithFormat:@"Parse error at line %lu of template %@: %@", (unsigned long)line, templateID, description];
        } else {
            localizedDescription = [NSString stringWithFormat:@"Parse error at line %lu: %@", (unsigned long)line, description];
        }
        [_delegate parser:self didFailWithError:[NSError errorWithDomain:GRMustacheErrorDomain
                                                                       code:GRMustacheErrorCodeParseError
                                                                   userInfo:[NSDictionary dictionaryWithObject:localizedDescription
                                                                                                        forKey:NSLocalizedDescriptionKey]]];
    }
}

- (NSRange)rangeOfString:(NSString *)needle inTemplateString:(NSString *)haystack startingAtIndex:(NSUInteger)p consumedNewLines:(NSUInteger *)outLines
{
    NSUInteger needleLength = needle.length;
    NSUInteger haystackLength = haystack.length;
    unichar firstNeedleChar = [needle characterAtIndex:0];
    unichar templateChar;
    
    assert(outLines);
    *outLines = 0;
    
    while (p + needleLength <= haystackLength) {
        templateChar = [haystack characterAtIndex:p];
        if (templateChar == '\n') {
            (*outLines)++;
        } else if (templateChar == firstNeedleChar && [[haystack substringWithRange:NSMakeRange(p, needle.length)] isEqualToString:needle]) {
            return NSMakeRange(p, needle.length);
        }
        p++;
    }
    
    return NSMakeRange(NSNotFound, 0);
}

- (NSArray *)parseKeyPath:(NSString *)innerTagString
{
    NSMutableArray *keys = [NSMutableArray array];
    
    enum {
        stateInitial,
        stateLeadingDot,
        stateIdentifier,
        stateWaitingForIdentifier,
        stateWhiteSpaceSuffix,
        stateError,
        stateValid
    } state = stateInitial;
    
//    stateInitial -> ' ' -> stateInitial
//    stateInitial -> '.' -> stateLeadingDot
//    stateInitial -> 'a' -> stateIdentifier
//    stateInitial -> EOF -> stateError
//    stateLeadingDot -> 'a' -> stateIdentifier
//    stateLeadingDot -> EOF -> stateValid
//    stateIdentifier -> 'a' -> stateIdentifier
//    stateIdentifier -> '.' -> stateWaitingForIdentifier
//    stateIdentifier -> ' ' -> stateWhiteSpaceSuffix
//    stateIdentifier -> EOF -> stateValid
//    stateWaitingForIdentifier -> 'a' -> stateIdentifier
//    stateWaitingForIdentifier -> EOF -> stateError
//    stateWhiteSpaceSuffix -> ' ' -> stateWhiteSpaceSuffix
//    stateWhiteSpaceSuffix -> EOF -> stateValid
    
    NSUInteger identifierStart = NSNotFound;
    NSUInteger length = innerTagString.length;
    for (NSUInteger i = 0; i < length; ++i) {
        unichar c = [innerTagString characterAtIndex:i];
        switch (state) {
            case stateInitial:
                switch (c) {
                    case ' ':
                    case '\n':
                    case '\t':
                        break;
                        
                    case '.':
                        [keys addObject:@"."];
                        state = stateLeadingDot;
                        break;
                        
                    default:
                        identifierStart = i;
                        state = stateIdentifier;
                        break;
                }
                break;
            
            case stateLeadingDot:
                switch (c) {
                    case ' ':
                    case '\n':
                    case '\t':
                        return nil;
                        
                    case '.':
                        return nil;
                        
                    default:
                        identifierStart = i;
                        state = stateIdentifier;
                        break;
                }
                break;
                
            case stateIdentifier:
                switch (c) {
                    case ' ':
                    case '\n':
                    case '\t':
                        [keys addObject:[innerTagString substringWithRange:(NSRange){ .location = identifierStart, .length = i - identifierStart }]];
                        state = stateWhiteSpaceSuffix;
                        break;
                        
                    case '.':
                        [keys addObject:[innerTagString substringWithRange:(NSRange){ .location = identifierStart, .length = i - identifierStart }]];
                        state = stateWaitingForIdentifier;
                        break;
                        
                    default:
                        break;
                }
                break;
                
            case stateWaitingForIdentifier:
                switch (c) {
                    case ' ':
                    case '\n':
                    case '\t':
                        return nil;
                        
                    case '.':
                        return nil;
                        
                    default:
                        identifierStart = i;
                        state = stateIdentifier;
                        break;
                }
                break;
                
            case stateWhiteSpaceSuffix:
                switch (c) {
                    case ' ':
                    case '\n':
                    case '\t':
                        break;
                        
                    case '.':
                        return nil;
                        
                    default:
                        return nil;
                        break;
                }
                break;
                
            default:
                NSAssert(NO, @"WTF");
                break;
        }
    }
    
    
    // EOF
    
    switch (state) {
        case stateInitial:
        case stateWaitingForIdentifier:
            state = stateError;
            break;
            
        case stateLeadingDot:
        case stateWhiteSpaceSuffix:
            state = stateValid;
            break;
            
        case stateIdentifier:
            [keys addObject:[innerTagString substringFromIndex:identifierStart]];
            state = stateValid;
            break;
            
        default:
            NSAssert(NO, @"WTF");
            break;
    }
    
    
    // End

    switch (state) {
        case stateError:
            return nil;
            
        case stateValid:
            return keys;
            
        default:
            NSAssert(NO, @"WTF");
            break;
    }
    
    return nil;
}

- (NSString *)parsePartialName:(NSString *)innerTagString
{
    NSString *partialName = [innerTagString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (partialName.length == 0) {
        return nil;
    }
    return partialName;
}

@end
