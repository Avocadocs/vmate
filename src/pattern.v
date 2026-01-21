module vmate

import regex

const all_custom_capture_indices_re = r'([$](\d+))|([$]\{(\d+):/((downcase)|(upcase)))'
const digit_re = r'\\\d+'

struct Capture {
mut:
	name     string
	rule     ?Rule
	patterns []Pattern
}

struct CaptureOption {
mut:
	name     string
	rule     ?Rule @[json: '-']
	patterns []PatternOptions
}

@[heap]
pub struct Pattern {
mut:
	grammar  &Grammar         = unsafe { nil }
	registry &GrammarRegistry = unsafe { nil }

	scope_name         string
	content_scope_name string

	include       string @[json: include]
	pop_rule      bool
	has_back_refs bool

	match_       string
	regex_source string

	captures map[string]CaptureOption

	push_rule ?&Rule

	anchored            bool
	has_back_references bool
}

pub struct PatternOptions {
	name         string
	content_name string @[json: 'scopeName']

	match_ string @[json: 'match']
	begin  string
	end    string

	patterns []PatternOptions

	captures       map[string]CaptureOption
	begin_captures map[string]CaptureOption @[json: 'beginCaptures']
	end_captures   map[string]CaptureOption @[json: 'endCaptures']

	include                string
	pop_rule               bool
	has_back_references    bool
	apply_end_pattern_last bool
}

fn has_back_referencess(pattern_string string) bool {
	for i := 0; i < pattern_string.len - 1; i++ {
		if pattern_string[i] == `\\` && pattern_string[i + 1].is_digit() {
			return true
		}
	}

	return false
}

pub fn new_pattern(mut grammar Grammar, mut registry GrammarRegistry, options PatternOptions) Pattern {
	assert !isnil(grammar)
	assert !isnil(registry)

	mut pattern := Pattern{
		grammar:            grammar
		registry:           registry
		scope_name:         options.name
		content_scope_name: options.content_name
		include:            options.include
		pop_rule:           options.pop_rule
	}

	has_digits := has_back_referencess(options.match_)
	pattern.has_back_references = has_digits

	if options.match_ != '' {
		if (options.end != '' || pattern.pop_rule) && has_digits {
			pattern.match_ = options.match_
		} else {
			pattern.regex_source = options.match_
		}
		pattern.captures = options.captures.clone()
	} else if options.begin != '' {
		pattern.regex_source = options.begin
		if options.begin_captures.len > 0 {
			pattern.captures = options.begin_captures.clone()
		} else {
			pattern.captures = options.captures.clone()
		}

		end_pattern := grammar.create_pattern(
			match_:   options.end
			captures: if options.end_captures.len > 0 {
				options.end_captures
			} else {
				options.captures
			}
			pop_rule: true
		)
		push_rule := grammar.create_rule(
			scope_name:             pattern.scope_name
			content_scope_name:     pattern.content_scope_name
			patterns:               options.patterns
			end_pattern:            end_pattern
			apply_end_pattern_last: options.apply_end_pattern_last
		)

		pattern.push_rule = &push_rule
	}

	for _, mut capture in pattern.captures {
		has_rule := if _ := capture.rule { true } else { false }

		if !has_rule && capture.patterns.len > 0 {
			capture.rule = grammar.create_rule(
				scope_name: pattern.scope_name
				patterns:   capture.patterns
			)
		}
	}

	pattern.anchored = pattern.has_anchor()
	return pattern
}

pub fn (p Pattern) get_regex(first_line bool, position int, anchor_position int) string {
	return if p.anchored {
		p.replace_anchor(first_line, position, anchor_position)
	} else {
		p.regex_source
	}
}

pub fn (p Pattern) has_anchor() bool {
	if p.regex_source == '' {
		return false
	}

	mut escape := false
	for character in p.regex_source {
		if escape && character.ascii_str() in ['A', 'G', 'z'] {
			return true
		}
		escape = (!escape && character.ascii_str() == '\\')
	}
	return false
}

pub fn (p Pattern) replace_anchor(first_line bool, offset int, anchor int) string {
	placeholder := '\uFFFF'
	mut escaped := []string{}
	mut escape := false

	for character in p.regex_source {
		if escape {
			match character.ascii_str() {
				'A' {
					escaped << if first_line { '\\A' } else { placeholder }
				}
				'G' {
					escaped << if offset == anchor { '\\G' } else { placeholder }
				}
				'z' {
					escaped << '$(?!\\n)(?<!\\n)'
				}
				else {
					escaped << '\\' + character.ascii_str()
				}
			}
			escape = false
		} else if character.ascii_str() == '\\' {
			escape = true
		} else {
			escaped << character.ascii_str()
		}
	}

	return escaped.join('')
}

pub fn (mut p Pattern) resolve_back_references(line string, begin_captures_indices []OnigGroup) Pattern {
	mut begin_captures := []string{}

	for capture in begin_captures_indices {
		// unsure
		if capture.start == -1 {
			begin_captures << ''
		} else {
			begin_captures << line.substr(capture.start, capture.end)
		}
	}

	mut ree := regex.regex_opt(digit_re) or { panic(err) }
	mut resolved_match := ree.replace_by_fn(p.match_, fn [begin_captures] (re regex.RE, in_txt string, start int, end int) string {
		index := in_txt.substr(start + 1, end).int()

		if begin_captures.len > index {
			return begin_captures[index]
		} else {
			return '\\${index}'
		}
	})

	return p.grammar.create_pattern(
		has_back_references: false
		match_:              resolved_match
		captures:            p.captures
		pop_rule:            p.pop_rule
	)
}

pub fn (mut p Pattern) rule_for_include(base_grammar &Grammar, name string) ?Rule {
	hash_index := name.index('#') or { -1 }

	if hash_index == 0 {
		return unsafe { p.grammar.get_repository()[name.substr(1, name.len)] }
	} else if hash_index >= 1 {
		grammar_name := name.substr(0, hash_index)
		rule_name := name.substr(hash_index + 1, name.len)
		p.grammar.add_included_grammar_scope(grammar_name)
		if grammar := p.registry.grammar_for_scope_name(grammar_name) {
			return unsafe { grammar.get_repository()[rule_name] }
		}
	} else if name == '\$self' {
		return p.grammar.get_initial_rule()
	} else if name == '\$base' {
		return base_grammar.get_initial_rule()
	} else {
		p.grammar.add_included_grammar_scope(name)
		if grammar := p.registry.grammar_for_scope_name(name) {
			return grammar.get_initial_rule()
		}
	}

	return none
}

pub fn (mut p Pattern) get_included_patterns(base_grammar &Grammar, mut included []&Rule) []Pattern {
	if p.include != '' {
		if mut rule := p.rule_for_include(base_grammar, p.include) {
			return rule.get_included_patterns(base_grammar, mut included)
		} else {
			return []
		}
	} else {
		return [p]
	}
}

pub fn (mut p Pattern) resolve_scope_name(scope_name string, line string, capture_indices []OnigGroup) string {
	mut re := regex.regex_opt(all_custom_capture_indices_re) or { panic(err) }

	return re.replace_by_fn(scope_name, fn [line, capture_indices, scope_name] (re regex.RE, in_txt string, _ int, _ int) string {
		// group 1 → $1
		// group 3 → ${1:...}
		// group 5 → command

		mut capture_index := -1
		mut command := ''

		g := re.get_group_list()
		g1 := g[1]
		g2 := g[3]
		g3 := g[5]

		if g1.end > g1.start {
			capture_index = scope_name.substr(g1.start, g1.end).int()
		} else if g2.end > g2.start {
			capture_index = scope_name.substr(g2.start, g2.end).int()
			command = scope_name.substr(g3.start, g3.end)
		} else {
			return re.get_group_by_id(in_txt, 0)
		}

		if capture_index < 0 || capture_index >= capture_indices.len {
			return re.get_group_by_id(in_txt, 0)
		}

		capture := capture_indices[capture_index]
		mut replacement := line[capture.start..capture.end]

		// Remove leading dots
		for replacement.len > 0 && replacement[0] == `.` {
			replacement = replacement[1..]
		}

		match command {
			'downcase' { return replacement.to_lower() }
			'upcase' { return replacement.to_upper() }
			else { return replacement }
		}
	})
}

struct StackItem {
mut:
	rule               &Rule
	scope_name         string
	content_scope_name string
	zero_width_match   bool
}

pub fn (mut p Pattern) handle_match(mut stack []&StackItem, line string, mut capture_indices []OnigGroup, rule Rule, end_pattern_match bool) []int {
	mut tags := []int{}

	zero_width_match := capture_indices[0].start == capture_indices[0].end
	mut scope_name := ''

	if p.pop_rule {
		if zero_width_match && stack.last().zero_width_match
			&& stack.last().rule.anchor_position == capture_indices[0].end {
			return []
		}
		content_scope_name := stack.last().content_scope_name
		if content_scope_name != '' {
			tags << content_scope_name.split(' ').reverse().map(p.grammar.end_id_for_scope(it))
		}
	} else if p.scope_name != '' {
		scope_name = p.resolve_scope_name(p.scope_name, line, capture_indices)
		tags << scope_name.split(' ').map(p.grammar.start_id_for_scope(it))
	}

	if p.captures.keys().len > 0 {
		mut io := capture_indices.clone()
		t := p.tags_for_capture_indices(line, mut io, capture_indices, mut stack)
		tags << t
	} else {
		start := capture_indices[0].start
		end := capture_indices[0].end
		if start != end {
			tags << end - start
		}
	}

	if mut push_rule := p.push_rule {
		mut rule_to_push := push_rule.get_rule_to_push(line, capture_indices)

		rule_to_push.anchor_position = capture_indices[0].end
		content_scope_name := rule_to_push.content_scope_name
		if content_scope_name != '' {
			csn := p.resolve_scope_name(content_scope_name, line, capture_indices)
			tags << csn.split(' ').map(p.grammar.start_id_for_scope(it))
		}
		stack << &StackItem{
			rule:               &rule_to_push
			scope_name:         scope_name
			content_scope_name: content_scope_name
			zero_width_match:   zero_width_match
		}
	} else {
		if p.pop_rule {
			scope_name = stack.pop().scope_name
		}
		if scope_name != '' {
			tags << scope_name.split(' ').reverse().map(p.grammar.end_id_for_scope(it))
		}
	}

	return tags
}

pub fn (mut p Pattern) tags_for_capture_rule(mut rule Rule, line string, capture_start int, capture_end int, mut stack []&StackItem) []int {
	capture_text := line.substr(capture_start, capture_end)

	mut sub_stack := stack.clone()
	sub_stack << &StackItem{
		rule: rule
	}

	tags := rule.grammar.tokenize_line(capture_text, mut sub_stack, false, true, false)

	mut open_scopes := []int{}
	mut capture_tags := []int{}
	mut offset := 0

	for tag in tags.tags {
		if !(tag < 0 || (tag > 0 && offset < capture_end)) {
			continue
		}

		capture_tags << tag
		if tag >= 0 {
			offset += tag
		} else {
			if tag % 2 == 0 {
				open_scopes.pop()
			} else {
				open_scopes << tag
			}
		}
	}

	for open_scopes.len > 0 {
		capture_tags << open_scopes.pop() - 1
	}

	return capture_tags
}

pub fn (mut p Pattern) tags_for_capture_indices(line string, mut current_capture_indices []OnigGroup, all_capture_indices []OnigGroup, mut stack []&StackItem) []int {
	parent_capture := current_capture_indices.pop_left()
	mut parent_capture_scope := ''

	mut tags := []int{}
	if parent_capture.index.str() in p.captures {
		scope := unsafe { p.captures[parent_capture.index.str()].name }
		if scope != '' {
			parent_capture_scope = p.resolve_scope_name(scope, line, all_capture_indices)
			tags << parent_capture_scope.split(' ').map(p.grammar.start_id_for_scope(it))
		}
	}

	if mut capture_rule := p.captures[parent_capture.index.str()].rule {
		capture_tags := p.tags_for_capture_rule(mut capture_rule, line, parent_capture.start,
			parent_capture.end, mut stack)
		tags << capture_tags

		for current_capture_indices.len > 0 && current_capture_indices[0].start < parent_capture.end {
			current_capture_indices.pop_left()
		}
	} else {
		mut previous_child_capture_end := parent_capture.start

		for current_capture_indices.len > 0 && current_capture_indices[0].start < parent_capture.end {
			child_capture := current_capture_indices[0]
			empty_capture := child_capture.end - child_capture.start == 0
			capture_has_no_scope := child_capture.index.str() !in p.captures
			if empty_capture || capture_has_no_scope {
				current_capture_indices.pop_left()
				continue
			}

			if child_capture.start > previous_child_capture_end {
				tags << child_capture.start - previous_child_capture_end
			}

			tags << p.tags_for_capture_indices(line, mut current_capture_indices, all_capture_indices, mut
				stack)
			previous_child_capture_end = child_capture.end
		}

		if parent_capture.end > previous_child_capture_end {
			tags << parent_capture.end - previous_child_capture_end
		}
	}

	if parent_capture_scope != '' {
		if tags.len > 1 {
			tags << parent_capture_scope.split(' ').reverse().map(p.grammar.end_id_for_scope(it))
		} else {
			tags.pop()
		}
	}

	return tags
}
