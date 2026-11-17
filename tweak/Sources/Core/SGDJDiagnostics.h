// Debug-only bridge: declared in Core, supplied by Shared's DJ queue.
#import <Foundation/Foundation.h>
#if SG_DRIVER
NSDictionary *SGDJQueueDiagnostics(void); // Main thread; includes physical voice items.
#endif
