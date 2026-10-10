#pragma once

namespace WebCore {
class RegisteredEventListener;
// Native listener metadata lives outside the fixed linked class layout. Entries
// are removed with their registration, including once, disposal and destruction.
void homeSetAbortListenerResistance(const RegisteredEventListener&);
bool homeHasAbortListenerResistance(const RegisteredEventListener&);
void homeRemoveAbortListenerResistance(const RegisteredEventListener&);
}
