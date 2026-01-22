module vmate


pub struct ScopeSelector {
	matcher MatcherWithPriority @[required]
}

pub fn new_scope_selector(source string) !ScopeSelector {
	matcher := create_matchers(source, name_matcher)
	return ScopeSelector{
		matcher: matcher[0]
	}
}

pub fn (s ScopeSelector) matches(scopes []string) bool {
	return s.matcher.matcher(scopes)
}

pub fn (s ScopeSelector) matches_string(scope string) bool {
	return s.matcher.matcher([scope])
}

pub fn (s ScopeSelector) get_prefix(scopes []string) string {
	return match s.matcher.priority {
		-1 {
			'L'
		}
		1 {
			'R'
		}
		else {
			''
		}
	}
}

