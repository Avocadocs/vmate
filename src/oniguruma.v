module vmate5

import prantlf.onig { RegEx }

@[heap]
struct OnigScanner {
mut:
	patterns []&RegEx
}

fn (os OnigScanner) str() string {
	return 'Pattern : d'
}

struct OnigGroup {
	index int
	start int
	end   int
}

pub struct OnigMatch {
pub mut:
	index           int
	capture_indices []OnigGroup
	scanner         &Scanner = unsafe { nil }
}

pub fn onig_scanner(patterns []string) OnigScanner {
	mut regexes := []&RegEx{}
	for pattern in patterns {
		regexes << onig.onig_new_utf8(pattern, onig.opt_none) or { panic(err) } // to do handle error
	}

	return OnigScanner{
		patterns: regexes
	}
}

pub fn (mut os OnigScanner) find_next_match_sync(text string, position int, scanner &Scanner) ?OnigMatch {
    mut best_location := int(1e9)
    mut best_result := ?OnigMatch(none)

    for i, mut re in os.patterns {
        // Search from current position
	    match_ := re.search_within(text, position, text.len, onig.opt_none ) or { continue }

        location := match_.groups[0].start

        // Rule 1: Earliest match wins. 
        // Rule 2: If locations are tied, the first rule in the loop stays (Implicit).
        if best_result == none || location < best_location {
            best_location = location
            
            mut capture_indices := []OnigGroup{}
            for j, capt in match_.groups {
                capture_indices << OnigGroup{
                    index: j
                    start: capt.start
                    end:   capt.end
                }
            }

            best_result = OnigMatch{
                index:           i
                capture_indices: capture_indices
                scanner:         scanner
            }
        }

        // Optimization: If it matches exactly at the current position, 
        // no subsequent rule can start earlier. Break immediately.
        if location == position {
            break
        }
    }
    return best_result
}
