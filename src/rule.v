module vmate

@[heap]
struct Rule {
mut:
	grammar  &Grammar         = unsafe { nil }
	registry &GrammarRegistry = unsafe { nil }

	scope_name         string
	content_scope_name string

	patterns []Pattern

	end_pattern            ?Pattern
	apply_end_pattern_last bool

	scanners_by_base_grammar_name map[string]&Scanner @[str: skip]
	create_end_pattern            ?Pattern            @[str: skip]

	anchor_position int = -1
	injections      Injections
}

pub struct RuleOptions {
	scope_name             string
	content_scope_name     string
	patterns               []PatternOptions
	end_pattern            ?Pattern
	apply_end_pattern_last bool
	include                string
}

pub fn new_rule(mut grammar Grammar, registry GrammarRegistry, options RuleOptions) Rule {
	mut rule := Rule{
		grammar:                grammar
		registry:               &registry
		scope_name:             options.scope_name
		content_scope_name:     options.content_scope_name
		end_pattern:            options.end_pattern
		apply_end_pattern_last: options.apply_end_pattern_last
	}

	for pattern in options.patterns {
		rule.patterns << grammar.create_pattern(pattern)
	}

	if end_pattern := rule.end_pattern {
		if !end_pattern.has_back_references {
			if rule.apply_end_pattern_last {
				rule.patterns << end_pattern
			} else {
				rule.patterns.prepend(end_pattern)
			}
		}
	}

	return rule
}

pub fn (mut r Rule) get_included_patterns(base_grammar &Grammar, mut included []&Rule) []Pattern {
	if &r in included {
		return []
	}

	included << &r
	mut all_patterns := []Pattern{}

	for mut pattern in r.patterns {
		all_patterns << pattern.get_included_patterns(base_grammar, mut included)
	}

	return all_patterns
}

pub fn (mut r Rule) clear_anchor_position() {
	r.anchor_position = -1
}

pub fn (mut r Rule) get_scanner(base_grammar &Grammar) &Scanner {
	if scanner := r.scanners_by_base_grammar_name[base_grammar.name] {
		return scanner
	}

	mut included := []Rule{}
	patterns := r.get_included_patterns(base_grammar, mut included)

	mut scanner := new_scanner(patterns)
	r.scanners_by_base_grammar_name[base_grammar.name] = &scanner

	return &scanner
}

pub fn (mut r Rule) scan_injections(rule_stack []&StackItem, line string, position int, first_line bool) ?OnigMatch {
	base_grammar := rule_stack[0].rule.grammar
	if mut injections := base_grammar.injections {
		for mut scanner in injections.get_scanners(rule_stack) {
			if result := scanner.find_next_match(line, first_line, position, r.anchor_position) {
				return result
			}
		}
	}

	return none
}

pub fn (mut r Rule) normalize_capture_indices(line string, capture_indices []OnigGroup) []OnigGroup {
	line_length := line.len

	mut new_capture_indices := []OnigGroup{}

	for capture in capture_indices {
		new_capture_indices << OnigGroup{
			start: int_min(capture.start, line_length)
			end:   int_min(capture.end, line_length)
			index: capture.index
		}
	}

	return new_capture_indices
}

pub fn (mut r Rule) find_next_match(mut rule_stack []&StackItem, line_with_new_line string, position int, first_line bool) ?OnigMatch {
	mut base_grammar := rule_stack[0].rule.grammar
	mut results := []OnigMatch{}

	mut main_scanner := r.get_scanner(base_grammar)
	if res := main_scanner.find_next_match(line_with_new_line, first_line, position, r.anchor_position) {
		results << res
	}

	if mut injections := base_grammar.injections {
		scopes := base_grammar.scopes_from_stack(rule_stack, &Rule{}, false)

		for mut inj in injections.injections {
			if inj.selector.matches(scopes) {
				mut scanner := injections.get_scanner(mut inj)
				if res := scanner.find_next_match(line_with_new_line, first_line, position,
					r.anchor_position)
				{
					// Check priority
					if inj.selector.get_prefix(scopes) == 'L' {
						results.prepend(res) // Left priority wins at same position
					} else {
						results << res
					}
				}
			}
		}
	}

	if results.len == 0 {
		return none
	}

	mut best := results[0]
	mut best_start := best.capture_indices[0].start

	for i := 1; i < results.len; i++ {
		current_start := results[i].capture_indices[0].start
		if current_start < best_start {
			best_start = current_start
			best = results[i]
		}
	}

	return OnigMatch{
		index:           best.index
		capture_indices: r.normalize_capture_indices(line_with_new_line, best.capture_indices)
		scanner:         best.scanner
	}
}

struct TagsResult {
	tags       []int
	tags_start int
	tags_end   int
}

pub fn (mut r Rule) get_next_tags(mut rule_stack []&StackItem, line string, line_with_new_line string, position int, first_line bool) ?TagsResult {
	if mut result := r.find_next_match(mut rule_stack, line_with_new_line, position, first_line) {
		mut end_pattern_match := false
		if end_pattern := r.end_pattern {
			if end_pattern == result.scanner.patterns[result.index] {
				end_pattern_match = true
			}
		}

		first_capture := result.capture_indices[0]

		if next_tags := result.scanner.handle_match(mut result, mut rule_stack, line,
			r, end_pattern_match)
		{
			return TagsResult{
				tags:       next_tags
				tags_start: first_capture.start
				tags_end:   first_capture.end
			}
		}
	}

	return none
}

pub fn (mut r Rule) get_rule_to_push(line string, begin_pattern_capture_indices []OnigGroup) Rule {
	if mut end_pattern := r.end_pattern {
		if end_pattern.has_back_references {
			mut rule := r.grammar.create_rule(
				scope_name:         r.scope_name
				content_scope_name: r.content_scope_name
			)
			resolved_end_pattern := end_pattern.resolve_back_references(line, begin_pattern_capture_indices)
			rule.end_pattern = resolved_end_pattern
			mut combined := [resolved_end_pattern]
			combined << r.patterns
			rule.patterns = combined

			return rule
		}
	}

	return r
}
