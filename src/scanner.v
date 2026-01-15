module vmate5

import prantlf.onig as _

@[heap]
struct Scanner {
	patterns []Pattern
	anchored bool
mut:
	anchored_scanner            ?OnigScanner
	first_line_anchored_scanner ?OnigScanner
	first_line_scanner          ?OnigScanner
	scanner                     ?OnigScanner
}

fn new_scanner(patterns []Pattern) Scanner {
	mut anchored := false

	for pattern in patterns {
		if pattern.anchored {
			anchored = true
			break
		}
	}

	return Scanner{
		patterns: patterns
		anchored: anchored
	}
}

fn (mut s Scanner) create_scanner(first_line bool, position int, anchor_position int) OnigScanner {
	patterns := s.patterns.map(fn [first_line, position, anchor_position] (w Pattern) string {
		regex := w.get_regex(first_line, position, anchor_position)
		if regex == '' {
			return 'undefined'
		} else {
			return regex
		}
	})
	
	return onig_scanner(patterns)
}

fn (mut s Scanner) get_scanner(first_line bool, position int, anchor_position int) ?OnigScanner {
	if !s.anchored {
		if scanner := s.scanner {
			return scanner
		}
		s.scanner = s.create_scanner(first_line, position, anchor_position)
		return s.scanner
	}

	if first_line {
		if position == anchor_position {
			if first_line_anchored_scanner := s.first_line_anchored_scanner {
				return first_line_anchored_scanner
			}
			s.first_line_anchored_scanner = s.create_scanner(first_line, position, anchor_position)
			return s.first_line_anchored_scanner?
		} else {
			if first_line_scanner := s.first_line_scanner {
				return first_line_scanner
			}
			s.first_line_scanner = s.create_scanner(first_line, position, anchor_position)
			return s.first_line_scanner?
		}
	} else if position == anchor_position {
		if anchored_scanner := s.anchored_scanner {
			return anchored_scanner
		}
		s.anchored_scanner = s.create_scanner(first_line, position, anchor_position)
		return s.anchored_scanner?
	} else {
		if scanner := s.scanner {
			return scanner
		}
		s.scanner = s.create_scanner(first_line, position, anchor_position)
		return s.scanner?
	}
}

fn (mut s Scanner) find_next_match(line string, first_line bool, position int, anchor_position int) ?OnigMatch {
	if mut scanner := s.get_scanner(first_line, position, anchor_position) {
		if mut match_ := scanner.find_next_match_sync(line, position, s) {
			return match_
		}
	}

	return none
}

fn (s &Scanner) handle_match(mut match_ OnigMatch, mut stack []StackItem, line string, rule &Rule, end_pattern_match bool) ?[]int {
	mut pattern := s.patterns[match_.index]

	return pattern.handle_match(mut stack, line, mut match_.capture_indices, rule, end_pattern_match)
}
