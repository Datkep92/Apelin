// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OwnGoal Studio
//
// The few Preferences.framework declarations a preference bundle subclasses.
// The SDK ships no Preferences headers, so these are Apelin's own, written
// from the framework's exported interface; nothing is copied from Apple.
// The symbols resolve from the private framework at run time; the link stub
// beside this folder (support/stubs/Preferences.framework) declares exactly
// what is used here. Add to both together.
#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class PSSpecifier;

@interface PSViewController : UIViewController
@end

@interface PSListController : PSViewController {
@protected
    NSMutableArray *_specifiers;
}

/// Loads the specifiers from <name>.plist inside the bundle that defines
/// `target`'s class.
- (NSMutableArray *)loadSpecifiersFromPlistName:(NSString *)plistName target:(id)target;
- (NSArray *)specifiers;
- (void)reloadSpecifiers;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
@end

@interface PSSpecifier : NSObject
@property (nonatomic, copy) NSString *identifier;
- (id)propertyForKey:(NSString *)key;
@end
