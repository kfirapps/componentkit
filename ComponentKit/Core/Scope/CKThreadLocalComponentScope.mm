/*
 *  Copyright (c) 2014-present, Facebook, Inc.
 *  All rights reserved.
 *
 *  This source code is licensed under the BSD-style license found in the
 *  LICENSE file in the root directory of this source tree. An additional grant
 *  of patent rights can be found in the PATENTS file in the same directory.
 *
 */

#import "CKThreadLocalComponentScope.h"

#import <pthread.h>
#import <stack>

#import <ComponentKit/CKAssert.h>

#import "CKComponentScopeRoot.h"

static pthread_key_t _threadKey() noexcept
{
  static pthread_key_t thread_key;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    (void)pthread_key_create(&thread_key, nullptr);
  });
  return thread_key;
}

CKThreadLocalComponentScope *CKThreadLocalComponentScope::currentScope() noexcept
{
  return (CKThreadLocalComponentScope *)pthread_getspecific(_threadKey());
}

CKThreadLocalComponentScope::CKThreadLocalComponentScope(CKComponentScopeRoot *previousScopeRoot,
                                                         const CKComponentStateUpdateMap &updates)
: newScopeRoot([previousScopeRoot newRoot]), stateUpdates(updates), stack(), previousScope(CKThreadLocalComponentScope::currentScope())
{
  stack.push({[newScopeRoot rootFrame], [previousScopeRoot rootFrame]});
  keys.push({});
  pthread_setspecific(_threadKey(), this);
  scopeHandlesMap = [NSMapTable strongToWeakObjectsMapTable];
}

CKThreadLocalComponentScope::~CKThreadLocalComponentScope()
{
  stack.pop();
  CKCAssert(stack.empty(), @"Didn't expect stack to contain anything in destructor");
  CKCAssert(keys.size() == 1 && keys.top().empty(), @"Expected keys to be at initial state in destructor");
  pthread_setspecific(_threadKey(), previousScope);
}

/** CKThreadLocalComponentIdentifier */

static pthread_key_t _threadIdentifierKey() noexcept
{
  static pthread_key_t thread_key;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    (void)pthread_key_create(&thread_key, nullptr);
  });
  return thread_key;
}

CKThreadLocalComponentIdentifier *CKThreadLocalComponentIdentifier::currentIdentifier() noexcept
{
  return (CKThreadLocalComponentIdentifier *)pthread_getspecific(_threadIdentifierKey());
}

CKThreadLocalComponentIdentifier::CKThreadLocalComponentIdentifier()
: stack(), classLevelStack()
{
  stack.push(@"");
  classLevelStack.push([NSMapTable weakToStrongObjectsMapTable]);
  classTypeMap = [NSMapTable weakToStrongObjectsMapTable];
  classTypeCounter = 0;
  pthread_setspecific(_threadIdentifierKey(), this);
}

void CKThreadLocalComponentIdentifier::pushComponentIdentifier(NSString *identifier)
{
  NSString *top = currentIdentifier()->stack.top();
  currentIdentifier()->stack.push([top stringByAppendingFormat:@"%@.",identifier]);
  classLevelStack.push([NSMapTable weakToStrongObjectsMapTable]);
  lastClass = nil;
}

void CKThreadLocalComponentIdentifier::popComponentIdentifier()
{
  classLevelStack.pop();
  stack.pop();
}

NSString* CKThreadLocalComponentIdentifier::nextComponentIdentifier(Class componentClass, BOOL forState)
{
  NSMapTable *typeCounterMap = classLevelStack.top();
  NSUInteger typeCounter = [[typeCounterMap objectForKey:componentClass] integerValue];
  if (!forState) {
    typeCounter++;
    [typeCounterMap setObject:@(typeCounter) forKey:componentClass];
    lastClass = componentClass;
  } else {
    // In case this identifier is being generated for the static state access, we need to check if the last class.
    if (lastClass != componentClass) {
      typeCounter++;
    }
  }
  NSString *typeCollisionIdentifier = (typeCounter > 1 ? [NSString stringWithFormat:@",%ld", typeCounter] : @"");
  NSString *componentIdentifier = [NSString stringWithFormat:@"%@%@%@",stack.top(), classTypeIdentifier(componentClass), typeCollisionIdentifier];
//  NSLog(@"componentIdentifier:%@",componentIdentifier);
  return componentIdentifier;
}

NSString* CKThreadLocalComponentIdentifier::classTypeIdentifier(Class componentClass) {
  id classTypeIdentifier = [classTypeMap objectForKey:componentClass];
  if (!classTypeIdentifier) {
    classTypeIdentifier = @(++classTypeCounter);
    [classTypeMap setObject:classTypeIdentifier forKey:componentClass];
  }
  return [NSString stringWithFormat:@"%@",classTypeIdentifier];
}

CKThreadLocalComponentIdentifier::~CKThreadLocalComponentIdentifier()
{
  stack.pop();
  classLevelStack.pop();
  CKCAssert(stack.empty(), @"Didn't expect stack to contain anything in destructor");
}
