#import <Foundation/Foundation.h>
#include <sys/utsname.h>
int main(int argc, const char *argv[]){
    @autoreleasepool {
        struct utsname u; uname(&u);
        NSLog(@"Device machine: %s", u.machine);
        NSLog(@"SDK quick test user: %@", NSUserName());
        NSLog(@"Documents path: %@", NSHomeDirectory());
    }
    return 0;
}
