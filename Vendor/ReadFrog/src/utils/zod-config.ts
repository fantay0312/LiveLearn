import { z } from "zod"
import "@/utils/iconify/local-icons"

// Disable Zod JIT (new Function) to avoid CSP eval violation in MV3 extensions
// https://github.com/colinhacks/zod/issues/4360
z.config({ jitless: true })
