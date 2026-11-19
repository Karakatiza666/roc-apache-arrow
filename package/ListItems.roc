## The source of `Items.from_list`: a Roc list read by index.
ListItems(item) :: { list : List(item) }.{

	## The source over a list. O(1), no copy.
	wrap : List(item) -> ListItems(item)
	wrap = |list| { list: list }

	## Item `j`. `Items` reads only `j < len`, so the crash branch is never taken.
	item_at : ListItems(item), U64 -> item
	item_at = |src, j| match src.list.get(j) {
		Ok(x) => x
		Err(OutOfBounds) => crash "ListItems: index past the list"
	}

	## An iterator over `count` items from `start`: a sublist, no copy.
	iter_range : ListItems(item), U64, U64 -> Iter(item)
	iter_range = |src, start, count| src.list.sublist({ start, len: count }).iter()
}
