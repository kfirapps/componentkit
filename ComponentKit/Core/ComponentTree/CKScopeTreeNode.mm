/*
 *  Copyright (c) 2014-present, Facebook, Inc.
 *  All rights reserved.
 *
 *  This source code is licensed under the BSD-style license found in the
 *  LICENSE file in the root directory of this source tree. An additional grant
 *  of patent rights can be found in the PATENTS file in the same directory.
 *
 */

#import "CKScopeTreeNode.h"

#import <algorithm>
#import <unordered_map>

#import <ComponentKit/CKGlobalConfig.h>

#import "CKThreadLocalComponentScope.h"
#import "CKTreeNodeProtocol.h"

NSUInteger const kTreeNodeParentBaseKey = 0;
NSUInteger const kTreeNodeOwnerBaseKey = 1;

@implementation CKScopeTreeNode

#pragma mark - CKTreeNodeWithChildrenProtocol

- (std::vector<id<CKTreeNodeProtocol>>)children
{
  std::vector<id<CKTreeNodeProtocol>> children;
  for (auto const &child : _children) {
    auto childKey = std::get<0>(child);
    if (std::get<1>(childKey) % 2 == kTreeNodeParentBaseKey) {
      children.push_back(std::get<1>(child));
    }
  }
  return children;
}

- (size_t)childrenSize
{
  return _children.size();
}

- (id<CKTreeNodeProtocol>)childForComponentKey:(const CKTreeNodeComponentKey &)key
{
  for (auto const &child : _children) {
    auto childKey = std::get<0>(child);
    if (childKey == key) {
      return std::get<1>(child);
    }
  }
  return nil;
}

- (CKTreeNodeComponentKey)createComponentKeyForChildWithClass:(id<CKComponentProtocol>)componentClass
                                                   identifier:(id<NSObject>)identifier
{
  // Create **parent** based key counter.
  NSUInteger keyCounter = kTreeNodeParentBaseKey;
  for (auto const &child : _children) {
    auto childKey = std::get<0>(child);
    if (std::get<0>(childKey) == componentClass && CKObjectIsEqual(std::get<2>(childKey), identifier)) {
      keyCounter += 2;
    }
  }
  static std::vector<id<NSObject>> empty;
  return std::make_tuple(componentClass, keyCounter, identifier, empty);
}

- (void)setChild:(id<CKTreeNodeProtocol>)child forComponentKey:(const CKTreeNodeComponentKey &)componentKey
{
  _children.push_back({componentKey, child});
}

- (void)didReuseInScopeRoot:(CKComponentScopeRoot *)scopeRoot fromPreviousScopeRoot:(CKComponentScopeRoot *)previousScopeRoot
{
  // In case that CKComponentScope was created, but not acquired from the component (for example: early nil return) ,
  // the component was never linked to the scope handle/tree node, hence, we should stop the recursion here.
  if (self.component == nil) {
    return;
  }

  NSLog(@"[1] %@ - %d - %p", self.component.class, self.nodeIdentifier, self);

  [super didReuseInScopeRoot:scopeRoot fromPreviousScopeRoot:previousScopeRoot];

  auto const mergeTreeNodesChildren = CKReadGlobalConfig().mergeTreeNodesChildren;

  for (auto const &child : _children) {
    auto childKey = std::get<0>(child);
    if (mergeTreeNodesChildren) {
      [std::get<1>(child) didReuseInScopeRoot:scopeRoot fromPreviousScopeRoot:previousScopeRoot];
    } else {
      if (std::get<1>(childKey) % 2 == kTreeNodeParentBaseKey) {
        [std::get<1>(child) didReuseInScopeRoot:scopeRoot fromPreviousScopeRoot:previousScopeRoot];
      }
    }
  }
}

#pragma mark - CKScopeTreeNodeProtocol

- (CKTreeNodeComponentKey)createKeyForComponentClass:(Class<CKComponentProtocol>)componentClass
                                          identifier:(id)identifier
                                                keys:(const std::vector<id<NSObject>> &)keys
{
  // Create **owner** based key counter.
  NSUInteger keyCounter = kTreeNodeOwnerBaseKey;
  for (auto const &child : _children) {
    auto childKey = std::get<0>(child);
    if (std::get<0>(childKey) == componentClass && CKObjectIsEqual(std::get<2>(childKey), identifier)) {
      keyCounter += 2;
    }
  }
  // Update the stateKey with the class key counter to make sure we don't have collisions.
  return std::make_tuple(componentClass, keyCounter, identifier, keys);
}

- (id<CKScopeTreeNodeProtocol>)childForKey:(const CKTreeNodeComponentKey &)key
{
  for (auto const &child : _children) {
    auto childKey = std::get<0>(child);
    if (childKey == key) {
      return (id<CKScopeTreeNodeProtocol>)std::get<1>(child);
    }
  }
  return nil;
}

- (void)setChild:(id<CKScopeTreeNodeProtocol>)child forKey:(const CKTreeNodeComponentKey &)key
{
  _children.push_back({key,child});
}

#pragma mark - CKComponentScopeFrameProtocol

+ (CKComponentScopeFramePair)childPairForPair:(const CKComponentScopeFramePair &)pair
                                      newRoot:(CKComponentScopeRoot *)newRoot
                               componentClass:(Class<CKComponentProtocol>)componentClass
                                   identifier:(id)identifier
                                         keys:(const std::vector<id<NSObject>> &)keys
                          initialStateCreator:(id (^)(void))initialStateCreator
                                 stateUpdates:(const CKComponentStateUpdateMap &)stateUpdates
{
  id<CKScopeTreeNodeProtocol> frame = (id<CKScopeTreeNodeProtocol>)pair.frame;
  id<CKScopeTreeNodeProtocol> previousFrame = (id<CKScopeTreeNodeProtocol>)pair.previousFrame;

  CKAssertNotNil(frame, @"Must have frame");
  CKAssert([frame conformsToProtocol:@protocol(CKScopeTreeNodeProtocol)], @"frame should conform to id<CKScopeTreeNodeProtocol> instead of %@", frame.class);
  CKAssert(previousFrame == nil || [previousFrame conformsToProtocol:@protocol(CKScopeTreeNodeProtocol)], @"previousFrame should conform to id<CKScopeTreeNodeProtocol> instead of %@", previousFrame.class);

  // Generate key inside the new parent
  CKTreeNodeComponentKey key = [frame createKeyForComponentClass:componentClass identifier:identifier keys:keys];
  // Get the child from the previous equivalent frame.
  CKScopeTreeNode *childFrameOfPreviousFrame = [previousFrame childForKey:key];

  // Create new handle.
  CKComponentScopeHandle *newHandle = childFrameOfPreviousFrame
  ? [childFrameOfPreviousFrame.scopeHandle newHandleWithStateUpdates:stateUpdates componentScopeRoot:newRoot]
  : [[CKComponentScopeHandle alloc] initWithListener:newRoot.listener
                                      rootIdentifier:newRoot.globalIdentifier
                                      componentClass:componentClass
                                        initialState:(initialStateCreator ? initialStateCreator() : [componentClass initialState])];

  // Create new node.
  CKScopeTreeNode *newChild = [[CKScopeTreeNode alloc]
                               initWithPreviousNode:childFrameOfPreviousFrame
                               scopeHandle:newHandle];

  // Link the tree node to the scope handle.
  [newHandle setTreeNode:newChild];

  // Insert the new node to its parent map.
  [frame setChild:newChild forKey:key];

  if (CKReadGlobalConfig().mergeTreeNodesChildren) {
    newChild->_componentKey = key;
  }
  return {.frame = newChild, .previousFrame = childFrameOfPreviousFrame};
}

#pragma mark - Helpers

#if DEBUG
// Iterate threw the nodes according to the **parent** based key
- (NSArray<NSString *> *)debugDescriptionNodes
{
  NSMutableArray<NSString *> *debugDescriptionNodes = [NSMutableArray arrayWithArray:[super debugDescriptionNodes]];
  for (auto const &child : _children) {
    auto const scopeNodeKey = std::get<0>(child);
    auto const childNode = std::get<1>(child);
    if (std::get<1>(scopeNodeKey) % 2 == kTreeNodeParentBaseKey) {
      for (NSString *s in [childNode debugDescriptionNodes]) {
        [debugDescriptionNodes addObject:[@"  " stringByAppendingString:s]];
      }
    }
  }
  return debugDescriptionNodes;
}

// Iterate threw the nodes according to the **owner** based key
- (NSArray<NSString *> *)debugDescriptionComponents
{
  NSMutableArray<NSString *> *childrenDebugDescriptions = [NSMutableArray new];
  for (auto const &child : _children) {
    auto const scopeNodeKey = std::get<0>(child);
    auto const childNode = std::get<1>(child);
    if (std::get<1>(scopeNodeKey) % 2 == kTreeNodeOwnerBaseKey) {
      auto const description = [NSString stringWithFormat:@"- %@%@%@",
                                NSStringFromClass(std::get<0>(scopeNodeKey)),
                                (std::get<2>(scopeNodeKey)
                                 ? [NSString stringWithFormat:@":%@", std::get<2>(scopeNodeKey)]
                                 : @""),
                                std::get<3>(scopeNodeKey).empty() ? @"" : formatKeys(std::get<3>(scopeNodeKey))];
      [childrenDebugDescriptions addObject:description];
      for (NSString *s in [(id<CKComponentScopeFrameProtocol>)childNode debugDescriptionComponents]) {
        [childrenDebugDescriptions addObject:[@"  " stringByAppendingString:s]];
      }
    }
  }
  return childrenDebugDescriptions;
}

static NSString *formatKeys(const std::vector<id<NSObject>> &keys)
{
  NSMutableArray<NSString *> *a = [NSMutableArray new];
  for (auto key : keys) {
    [a addObject:[key description] ?: @"(null)"];
  }
  return [a componentsJoinedByString:@", "];
}

#endif
@end
