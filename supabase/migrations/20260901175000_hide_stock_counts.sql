-- Customers must not see how a drop is allocated. Hiding numbers in the page is
-- not enough: anyone with the publishable key could read release_inventory
-- directly. Anonymous read is withdrawn and replaced by get_availability(slug),
-- which answers only "can this size still be reserved at this store?".
drop policy if exists inventory_public_read on public.release_inventory;
