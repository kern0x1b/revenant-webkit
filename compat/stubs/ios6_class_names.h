/* The renamed class name as a string, for the few NSClassFromString() lookups.
 * Kept apart from the renames themselves so that a build without the prefix
 * still has the macro: there the name stringifies to itself. */
#ifndef IOS6_CLASS_NAMES_H
#define IOS6_CLASS_NAMES_H
#define IOS6_CLASS_NAME_(x) #x
#define IOS6_CLASS_NAME(x) IOS6_CLASS_NAME_(x)
#endif
