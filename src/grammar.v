module vmate

import prantlf.onig { RegEx }

@[heap]
pub struct Grammar {
mut:
	registry &GrammarRegistry = unsafe { nil }

	name                string
	file_types          []string
	scope_name          string
	folding_stop_marker string

	max_tokens_per_line int = 99999
	max_line_length     int = 99999

	first_line_regex ?&RegEx
	content_regex    ?&RegEx

	included_grammar_scopes []string

	repository   map[string]Rule
	initial_rule Rule

	raw_patterns   []PatternOptions
	raw_repository map[string]PatternOptions
	path           string
}

struct GrammarOptions {
	name                string
	file_types          []string @[json: 'fileTypes']
	scope_name          string   @[json: 'scopeName']
	folding_stop_marker string
	max_tokens_per_line int
	max_line_length     int
	patterns            []PatternOptions
	repository          map[string]PatternOptions
	first_line_match    string
	content_regex       string
}

pub fn new_grammar(registry &GrammarRegistry, options GrammarOptions) Grammar {
	first_line_match := if options.first_line_match != '' {
		onig.onig_new(options.first_line_match, onig.opt_none) or { panic(err) }
	} else {
		none
	}

	content_regex := if options.content_regex != '' {
		onig.onig_new(options.content_regex, onig.opt_none) or { panic(err) }
	} else {
		none
	}

	mut grammar := Grammar{
		registry: unsafe { registry }

		name:                options.name
		file_types:          options.file_types
		scope_name:          options.scope_name
		folding_stop_marker: options.folding_stop_marker
		first_line_regex:    first_line_match
		content_regex:       content_regex

		raw_patterns:   options.patterns
		raw_repository: options.repository
	}

	grammar.update_rules()

	return grammar
}

pub fn (mut g Grammar) tokenize_lines(text string, compatibility_mode bool) [][]Token {
	lines := text.split('\n')
	last_line := lines.len - 1
	mut rule_stack := []&StackItem{}
	mut scopes := []int{}

	mut results := [][]Token{}

	for line_number, line in lines {
		res := g.tokenize_line(line, mut rule_stack.clone(), line_number == 0, compatibility_mode,
			line_number != last_line)
		rule_stack = res.rule_stack.clone()
		results << g.registry.decode_tokens(line + '\n', res.tags, mut scopes)
	}

	return results
}

pub struct TokenizeResult {
pub mut:
	line            string
	open_scope_tags []int
	tags            []int
	rule_stack      []&StackItem
}

pub fn (mut g Grammar) tokenize_line(input_line string, mut rule_stack []&StackItem, first_line bool, compatibility_mode bool, append_new_line bool) TokenizeResult {
	mut tags := []int{}

	mut truncated_line := false
	mut line := ''
	if input_line.len > g.max_line_length {
		line = input_line.substr(0, g.max_line_length)
		truncated_line = true
	} else {
		line = input_line
	}

	mut open_scope_tags := []int{}

	if rule_stack.len > 0 {
		if compatibility_mode {
			for item in rule_stack {
				if item.scope_name != '' {
					open_scope_tags << item.scope_name.split(' ').map(g.registry.start_id_for_scope(it))
				}
				if item.content_scope_name != '' {
					open_scope_tags << item.content_scope_name.split(' ').map(g.registry.start_id_for_scope(it))
				}
			}
		}
	} else {
		if compatibility_mode {
			open_scope_tags = []int{}
		}
		rule_stack = [&StackItem{
			rule:               &g.initial_rule
			scope_name:         g.initial_rule.scope_name
			content_scope_name: g.initial_rule.content_scope_name
		}]
		if g.initial_rule.scope_name != '' {
			tags << g.initial_rule.scope_name.split(' ').map(g.start_id_for_scope(it))
		}
		if g.initial_rule.content_scope_name != '' {
			tags << g.initial_rule.content_scope_name.split(' ').map(g.start_id_for_scope(it))
		}
	}

	initial_rule_stack_length := rule_stack.len
	mut position := 0
	mut token_count := 0

	for {
		previous_rule_stack_length := rule_stack.len
		previous_position := position

		if position > line.len {
			break
		}

		if token_count >= g.get_max_tokens_per_line() - 1 {
			truncated_line = true
			break
		}

		mut last_item := rule_stack.last()

		if match_ := last_item.rule.get_next_tags(mut rule_stack, line, line + '\n', position,
			first_line)
		{
			if position < match_.tags_start {
				tags << match_.tags_start - position
				token_count++
			}

			tags << match_.tags
			for tag in match_.tags {
				if tag >= 0 {
					token_count++
				}
			}

			position = match_.tags_end
		} else {
			if position < line.len || line.len == 0 {
				tags << line.len - position
			}
			break
		}

		if position == previous_position {
			if rule_stack.len == previous_rule_stack_length {
				println('Popping rule because it loops at column ${position} of line ${line}')
				if rule_stack.len > 1 {
					ab := rule_stack.pop()
					if ab.content_scope_name != '' {
						tags << ab.content_scope_name.split(' ').map(g.end_id_for_scope(it))
					}
					if ab.scope_name != '' {
						tags << ab.scope_name.split(' ').reverse().map(g.end_id_for_scope(it))
					}
				} else {
					if position < line.len || (line.len == 0 && tags.len == 0) {
						tags << line.len - position
					}
					break
				}
			} else if rule_stack.len > previous_rule_stack_length {
				mut penultimate_rule := rule_stack[rule_stack.len - 2].rule
				mut last_rule := rule_stack[rule_stack.len - 1].rule
				mut pop_stack := false

				if last_rule == penultimate_rule {
					pop_stack = true
				}

				if last_rule.scope_name != '' && last_rule.scope_name == penultimate_rule.scope_name {
					pop_stack = true
				}

				if pop_stack {
					rule_stack.pop()
					last_symbol := tags.last()
					if last_symbol < 0 && last_symbol == g.start_id_for_scope(last_rule.scope_name) {
						tags.pop()
					}
					tags << line.len - position
					break
				}
			}
		}
	}

	if truncated_line {
		tag_count := tags.len

		if tags[tag_count - 1] > 0 {
			tags[tag_count - 1] += input_line.len - position
		} else {
			tags << input_line.len - position
		}
		for rule_stack.len > initial_rule_stack_length {
			ab := rule_stack.pop()

			if ab.content_scope_name != '' {
				tags << g.end_id_for_scope(ab.content_scope_name)
			}

			if ab.scope_name != '' {
				tags << g.end_id_for_scope(ab.scope_name)
			}
		}
	}

	for mut item in rule_stack {
		item.rule.clear_anchor_position()
	}

	return TokenizeResult{
		line:            input_line
		open_scope_tags: open_scope_tags
		tags:            tags
		rule_stack:      rule_stack
	}
}

fn (mut g Grammar) update_rules() {
	g.initial_rule = g.create_rule(
		scope_name: g.scope_name
		patterns:   g.raw_patterns
	)
	g.repository = g.create_repository()
}

fn (g Grammar) get_initial_rule() Rule {
	return g.initial_rule
}

fn (g Grammar) get_repository() map[string]Rule {
	return g.repository
}

fn (mut g Grammar) create_repository() map[string]Rule {
	mut repository := map[string]Rule{}

	for name, data in g.raw_repository {
		if data.begin != '' || data.match_ != '' {
			// It's a single rule definition
			repository[name] = g.create_rule(
				patterns: [data]
			)
		} else {
			// It's a collection or a direct include
			repository[name] = g.create_rule(
				patterns: data.patterns
				include:  data.include
			)
		}
	}
	return repository
}

fn (mut g Grammar) add_included_grammar_scope(scope string) {
	if scope !in g.included_grammar_scopes {
		g.included_grammar_scopes << scope
	}
}

fn (mut g Grammar) start_id_for_scope(scope string) int {
	return g.registry.start_id_for_scope(scope)
}

fn (mut g Grammar) end_id_for_scope(scope string) int {
	return g.registry.end_id_for_scope(scope)
}

fn (g Grammar) scope_for_id(id int) string {
	return g.registry.scope_for_id(id)
}

fn (mut g Grammar) create_rule(options RuleOptions) Rule {
	return new_rule(mut g, g.registry, options)
}

fn (mut g Grammar) create_pattern(options PatternOptions) Pattern {
	return new_pattern(mut g, mut g.registry, options)
}

fn (g Grammar) get_max_tokens_per_line() int {
	return g.max_tokens_per_line
}

fn (mut g Grammar) scopes_from_stack(stack []&Rule, rule &Rule, end_pattern_match bool) []string {
	mut scopes := []string{}

	for item in stack {
		if item.scope_name != '' {
			scopes << item.scope_name
		}
		if item.content_scope_name != '' {
			scopes << item.content_scope_name
		}
	}

	if end_pattern_match && rule.content_scope_name != '' && rule == stack.last() {
		scopes.pop()
	}

	return scopes
}
