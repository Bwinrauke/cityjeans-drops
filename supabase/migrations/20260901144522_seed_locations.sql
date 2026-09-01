-- The nine retail pickup locations, mirrored from the Shopify location list.
insert into public.locations (name, address, phone, sort_order) values
  ('City Jeans 170th St',      '3 East 170th Street, Bronx, NY 10452',    '(718) 293-8780', 1),
  ('Ownership 170th St',       '6 East 170th Street, Bronx, NY 10452',    '(718) 590-5066', 2),
  ('Vault 170th St',           '1 East 170th Street, Bronx, NY 10452',    '(347) 591-4990', 3),
  ('City Jeans Fordham Rd',    '306 East Fordham Road, Bronx, NY 10458',  '(718) 367-4977', 4),
  ('City Jeans Tremont Ave',   '690 East Tremont Avenue, Bronx, NY 10457','(718) 583-0424', 5),
  ('City Jeans Third Ave',     '2996 3rd Avenue, Bronx, NY 10455',        '(718) 401-5919', 6),
  ('City Jeans Bruckner',      '1935 Turnbull Avenue, Bronx, NY 10473',   '(718) 829-2620', 7),
  ('City Jeans West 225th',    '48 West 225th Street, New York, NY 10463','(718) 220-3940', 8),
  ('City Jeans Junction Blvd', '3739 Junction Boulevard, Corona, NY 11368','(347) 813-4920', 9);
