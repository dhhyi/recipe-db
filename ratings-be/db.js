module.exports = () => {
  const data = { ratings: [] };
  // Create 1000 ratings
  for (let i = 0; i < 1000; i++) {
    data.ratings.push({ id: i, rating: Math.trunc(Math.random() * 6) });
  }
  return data;
};
